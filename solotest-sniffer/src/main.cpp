// Sniffer serial — decodifica o protocolo de uma prensa pela serial.
// Le Serial2 (prensa via MAX3232, GPIO16=RX, GPIO17=TX) e imprime o dado CRU
// (hex + ASCII) no Serial USB (115200). Mostra os numeros candidatos a carga.
//
// Solotest: ja sabemos 9600 8N1 (do integrador .NET deles). Se nao vier nada,
// descomente BAUD_SCAN p/ varrer outras velocidades.
//
// Ligacao: Prensa RS-232 -> MAX3232 -> ESP32  (VCC=3V3, GND, TXD->GPIO16, RXD->GPIO17)

#include <Arduino.h>

#define PRENSA_BAUD   9600     // Solotest (confirmado no integrador deles)
#define PRENSA_RX     16       // GPIO16 <- TXD do MAX3232
#define PRENSA_TX     17       // GPIO17 -> RXD do MAX3232
//#define BAUD_SCAN            // descomente p/ varrer bauds se 9600 nao funcionar

const int BAUDS[] = {9600, 19200, 4800, 38400, 2400, 115200};

void escutar(int baud, unsigned long ms) {
  Serial2.begin(baud, SERIAL_8N1, PRENSA_RX, PRENSA_TX);
  Serial.printf("\n===== escutando %d baud 8N1 (%lus) — faca uma leitura/ruptura na prensa =====\n", baud, ms / 1000);
  String linha; String hexs;
  unsigned long t0 = millis(), totais = 0;
  while (millis() - t0 < ms) {
    while (Serial2.available()) {
      uint8_t c = Serial2.read();
      totais++;
      char h[4]; snprintf(h, sizeof(h), "%02X ", c); hexs += h;
      if (c == '\r' || c == '\n') {
        if (linha.length()) {
          // destaca numeros candidatos a carga
          Serial.printf("ASCII: %-24s | HEX: %s\n", ("'" + linha + "'").c_str(), hexs.c_str());
          linha = ""; hexs = "";
        }
      } else if (c >= 32 && c < 127) {
        linha += (char)c;
      } else {
        linha += '.';   // byte nao-imprimivel
      }
    }
  }
  if (linha.length()) Serial.printf("ASCII(parcial): '%s' | HEX: %s\n", linha.c_str(), hexs.c_str());
  Serial.printf("----- %lu bytes recebidos em %d baud -----\n", totais, baud);
  Serial2.end();
}

void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println("\n[sniffer] pronto. Ligue a prensa no MAX3232 e provoque uma leitura.");
}

void loop() {
#ifdef BAUD_SCAN
  for (int b : BAUDS) escutar(b, 8000);     // varre cada baud por 8s
#else
  escutar(PRENSA_BAUD, 30000);              // fica em 9600, janelas de 30s
#endif
}
