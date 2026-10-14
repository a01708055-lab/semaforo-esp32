# Semáforo ESP32 + Web

Página web que refleja en tiempo real el estado de un ESP32 conectado por USB, con cuenta regresiva.

## Estructura

```
semaforo/
├── index.html                  # Interfaz web (fiel al Figma + mejoras)
├── server.py                   # Servidor puente Serial -> Web (SSE + API)
├── semaforo_esp32/
│   └── semaforo_esp32.ino      # Firmware ESP32
└── README.md
```

## Cómo funciona

```
ESP32 (pins 2/4/5) --USB Serial 115200--> server.py --SSE /events--> index.html
   envía {"estado":"rojo","restante":19} cada segundo
```

## Uso rápido

1. **Subir firmware:** abre `semaforo_esp32/semaforo_esp32.ino` en Arduino IDE,
   selecciona placa ESP32, sube el código.
   Conexiones: pin 2 → LED rojo (+resistencia 220Ω), pin 4 → amarillo,
   pin 5 → verde. Cátodos a GND.

2. **Arrancar servidor:**
```bash
pip install pyserial
python server.py --port COM3   # en Windows mira en Administrador de dispositivos
# python server.py --port /dev/ttyUSB0   # Linux/Mac
# python server.py --simulate             # sin ESP32, simula los mismos tiempos
```
Sin Python instalado (solo Windows):
```powershell
# Con ESP32 real en COM3:
powershell -ExecutionPolicy Bypass -File servidor_com3.ps1 -ComPort COM3 -WebPort 8000
# Solo simulación (sin hardware):
powershell -ExecutionPolicy Bypass -File servidor.ps1 -Port 8000
```

3. **Abrir página:** http://localhost:8000

## Protocolo Serial (una línea JSON por segundo)

```json
{"estado":"rojo","restante":19,"duracion":20,"pin":2}
```

Estados: `rojo` (20 s, pin 2), `verde` (15 s, pin 5), `amarillo` (5 s, pin 4).
Secuencia: verde → amarillo → rojo → (repite).

## API del servidor

- `GET /` → página web
- `GET /api/status` → `{"estado":"verde","restante":12,...,"conectado":true,"puerto":"COM3"}`
- `GET /events` → Server-Sent Events con el mismo JSON en cada cambio/segundo
