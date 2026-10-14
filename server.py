"""
Servidor puente Semáforo ESP32 -> Web.
- Lee el puerto serial USB (115200 baud) donde el ESP32 envía una línea JSON por segundo:
    {"estado":"rojo","restante":19,"duracion":20,"pin":2}
- Expone:
    GET /            -> index.html
    GET /api/status  -> JSON con el último estado
    GET /events      -> Server-Sent Events (actualización en vivo)
- Si no hay ESP32 conectado (o se pasa --simulate), simula la misma secuencia
  rojo 20 s / verde 15 s / amarillo 5 s para poder probar la página.

Solo requiere stdlib. Para modo hardware: pip install pyserial
Uso:
    python server.py --port COM3          (Windows)
    python server.py --port /dev/ttyUSB0  (Linux/Mac)
    python server.py --simulate           (sin hardware)
    python server.py --http-port 8000
"""
import argparse
import json
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DURACIONES = {"rojo": 20, "verde": 15, "amarillo": 5}
PINES = {"rojo": 2, "amarillo": 4, "verde": 5}
SECUENCIA = ["verde", "amarillo", "rojo"]  # ciclo continuo

state = {
    "estado": "rojo",
    "restante": 20,
    "duracion": 20,
    "pin": 2,
    "conectado": False,
    "puerto": "simulado",
    "fuente": "simulacion",
    "actualizado": time.time(),
}
_subs: list[queue.Queue] = []
_lock = threading.Lock()


def publish(s: dict):
    with _lock:
        state.update(s)
        state["actualizado"] = time.time()
        for q in list(_subs):
            try:
                q.put_nowait(dict(state))
            except queue.Full:
                pass


def serial_reader(port: str, baud: int = 115200):
    """Lee líneas JSON del ESP32 y las publica. Reintenta si se desconecta."""
    try:
        import serial  # pyserial
    except ImportError:
        print("[ERROR] pyserial no instalado. Ejecuta: pip install pyserial "
              "o usa --simulate")
        return
    while True:
        try:
            print(f"[serial] conectando a {port} @ {baud}...")
            with serial.Serial(port, baud, timeout=1) as ser:
                print(f"[serial] conectado a {port}")
                buf = b""
                while True:
                    chunk = ser.read(64)
                    if chunk:
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            line = line.decode("utf-8", "replace").strip()
                            if not line:
                                continue
                            try:
                                msg = json.loads(line)
                            except json.JSONDecodeError:
                                continue  # ignora líneas no JSON (boot del ESP32, etc.)
                            estado = str(msg.get("estado", "")).lower()
                            if estado not in DURACIONES:
                                continue
                            publish({
                                "estado": estado,
                                "restante": int(msg.get("restante", DURACIONES[estado])),
                                "duracion": int(msg.get("duracion", DURACIONES[estado])),
                                "pin": int(msg.get("pin", PINES[estado])),
                                "conectado": True,
                                "puerto": port,
                                "fuente": "esp32",
                            })
                    else:
                        # Sin datos >3 s: marca desconectado pero conserva último estado
                        if time.time() - state["actualizado"] > 3 and state["conectado"]:
                            publish({"conectado": False})
        except Exception as e:
            publish({"conectado": False})
            print(f"[serial] {e}. Reintentando en 3 s...")
            time.sleep(3)


def simulator():
    """Genera la misma secuencia del ESP32 para probar sin hardware."""
    i = SECUENCIA.index("rojo") if state["estado"] in SECUENCIA else 0
    while True:
        estado = SECUENCIA[i % len(SECUENCIA)]
        dur = DURACIONES[estado]
        for rest in range(dur, 0, -1):
            publish({
                "estado": estado, "restante": rest, "duracion": dur,
                "pin": PINES[estado], "conectado": True,
                "puerto": "simulado", "fuente": "simulacion",
            })
            time.sleep(1)
        i += 1


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html = (Path(__file__).parent / "index.html").read_bytes()
            self._send(200, html, "text/html; charset=utf-8")
        elif self.path == "/api/status":
            with _lock:
                body = json.dumps(state).encode()
            self._send(200, body, "application/json")
        elif self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            q: queue.Queue = queue.Queue(maxsize=10)
            with _lock:
                _subs.append(q)
                q.put_nowait(dict(state))
            try:
                while True:
                    msg = q.get()
                    self.wfile.write(f"data: {json.dumps(msg)}\n\n".encode())
                    self.wfile.flush()
            except (ConnectionError, BrokenPipeError):
                pass
            finally:
                with _lock:
                    if q in _subs:
                        _subs.remove(q)
        else:
            self._send(404, b"no encontrado", "text/plain")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM3", help="Puerto serial del ESP32")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--http-port", type=int, default=8000)
    ap.add_argument("--simulate", action="store_true", help="Probar sin ESP32")
    args = ap.parse_args()

    if args.simulate:
        threading.Thread(target=simulator, daemon=True).start()
        print("[modo] simulación (sin hardware)")
    else:
        threading.Thread(target=serial_reader, args=(args.port, args.baud),
                         daemon=True).start()

    srv = ThreadingHTTPServer(("0.0.0.0", args.http_port), Handler)
    print(f"[web] http://localhost:{args.http_port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
