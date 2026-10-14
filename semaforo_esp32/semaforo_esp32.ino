/*
  Semáforo con ESP32 + reporte a página web vía Serial USB.

  Conexiones (LED + resistencia 220 ohm en serie, cátodo a GND):
    Rojo     -> GPIO 2  (20 segundos)
    Amarillo -> GPIO 4  ( 5 segundos)
    Verde    -> GPIO 5  (15 segundos)

  Secuencia: VERDE (15 s) -> AMARILLO (5 s) -> ROJO (20 s) -> repite.

  Cada segundo envía por Serial (115200 baud) una línea JSON que el
  servidor (server.py) reenvía a la página web:
    {"estado":"rojo","restante":19,"duracion":20,"pin":2}

  Placa: ESP32 Dev Module. Sin librerías externas.
*/

#define PIN_ROJO 2        // exigido por el enunciado (20 s)
#define PIN_AMARILLO 4    // libre elección (5 s)
#define PIN_VERDE 5       // libre elección (15 s)

#define DUR_ROJO 20
#define DUR_AMARILLO 5
#define DUR_VERDE 15

enum Luz { VERDE, AMARILLO, ROJO };

Luz luzActual = VERDE;
unsigned long inicioFase = 0;
int ultimoRestante = -1;

int duracionDe(Luz l) {
  if (l == ROJO) return DUR_ROJO;
  if (l == AMARILLO) return DUR_AMARILLO;
  return DUR_VERDE;
}

int pinDe(Luz l) {
  if (l == ROJO) return PIN_ROJO;
  if (l == AMARILLO) return PIN_AMARILLO;
  return PIN_VERDE;
}

const char* nombreDe(Luz l) {
  if (l == ROJO) return "rojo";
  if (l == AMARILLO) return "amarillo";
  return "verde";
}

void aplicarLuz(Luz l) {
  digitalWrite(PIN_ROJO, l == ROJO ? HIGH : LOW);
  digitalWrite(PIN_AMARILLO, l == AMARILLO ? HIGH : LOW);
  digitalWrite(PIN_VERDE, l == VERDE ? HIGH : LOW);
}

void reportar(int restante) {
  // Una línea JSON por segundo: la página muestra "restante" como cuenta regresiva.
  Serial.print("{\"estado\":\"");
  Serial.print(nombreDe(luzActual));
  Serial.print("\",\"restante\":");
  Serial.print(restante);
  Serial.print(",\"duracion\":");
  Serial.print(duracionDe(luzActual));
  Serial.print(",\"pin\":");
  Serial.print(pinDe(luzActual));
  Serial.println("}");
}

void setup() {
  pinMode(PIN_ROJO, OUTPUT);
  pinMode(PIN_AMARILLO, OUTPUT);
  pinMode(PIN_VERDE, OUTPUT);
  Serial.begin(115200);
  delay(500);
  aplicarLuz(luzActual);
  inicioFase = millis();
  ultimoRestante = -1;
}

void loop() {
  int dur = duracionDe(luzActual);
  int transcurrido = (millis() - inicioFase) / 1000;
  int restante = dur - transcurrido;

  if (restante <= 0) {
    // Avanza a la siguiente fase del semáforo
    if (luzActual == VERDE) luzActual = AMARILLO;
    else if (luzActual == AMARILLO) luzActual = ROJO;
    else luzActual = VERDE;
    aplicarLuz(luzActual);
    inicioFase = millis();
    ultimoRestante = -1;
    return;
  }

  if (restante != ultimoRestante) {
    ultimoRestante = restante;
    reportar(restante);
  }
  delay(50);
}
