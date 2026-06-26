// Prober ATIVO de prensa query/resposta (ex.: DIGITEC).
// O ESP32 ENVIA comandos candidatos pela Serial2 (via MAX3232) e escuta a resposta.
// Varre comandos x bauds e mostra qual combinacao faz a prensa responder.
//
// Ligacao: Prensa RS-232 <-> MAX3232 <-> ESP32 (GPIO16=RX, GPIO17=TX, GND comum, VCC=3V3)

#include <Arduino.h>

#define RX_PIN 16
#define TX_PIN 17

const int BAUDS[] = {9600, 19200, 4800, 2400, 38400};

// comandos candidatos (os mais comuns em indicadores/balancas)
struct Cmd { const char* nome; const uint8_t* bytes; size_t len; };
const uint8_t C_ENQ[]   = {0x05};
const uint8_t C_CR[]    = {0x0D};
const uint8_t C_P[]     = {'P', 0x0D};
const uint8_t C_PCRLF[] = {'P', 0x0D, 0x0A};
const uint8_t C_Q[]     = {'?', 0x0D};
const uint8_t C_R[]     = {'R', 0x0D};
const uint8_t C_D[]     = {'D', 0x0D};
const uint8_t C_S[]     = {'S', 0x0D};
const uint8_t C_W[]     = {'W', 0x0D};
const uint8_t C_DC1[]   = {0x11};        // XON
const uint8_t C_PRINT[] = {'P','R','I','N','T',0x0D};
const uint8_t C_STX[]   = {0x02};        // STX
const Cmd CMDS[] = {
  {"ENQ(0x05)", C_ENQ, 1}, {"CR", C_CR, 1}, {"P\\r", C_P, 2}, {"P\\r\\n", C_PCRLF, 3},
  {"?\\r", C_Q, 2}, {"R\\r", C_R, 2}, {"D\\r", C_D, 2}, {"S\\r", C_S, 2},
  {"W\\r", C_W, 2}, {"DC1(0x11)", C_DC1, 1}, {"PRINT\\r", C_PRINT, 6}, {"STX(0x02)", C_STX, 1},
};

void dump(const uint8_t* b, size_t n) {
  String hex, asc;
  for (size_t i = 0; i < n; i++) {
    char h[4]; snprintf(h, sizeof(h), "%02X ", b[i]); hex += h;
    asc += (b[i] >= 32 && b[i] < 127) ? (char)b[i] : '.';
  }
  Serial.printf("RESP(%u): HEX %s| ASCII '%s'\n", (unsigned)n, hex.c_str(), asc.c_str());
}

void probarBaud(int baud) {
  Serial2.begin(baud, SERIAL_8N1, RX_PIN, TX_PIN);
  delay(50);
  Serial.printf("\n========== BAUD %d ==========\n", baud);
  for (auto& c : CMDS) {
    while (Serial2.available()) Serial2.read();   // limpa
    Serial2.write(c.bytes, c.len);
    Serial2.flush();
    // escuta resposta por ~1.2s
    uint8_t buf[128]; size_t n = 0;
    unsigned long t0 = millis();
    while (millis() - t0 < 1200) {
      while (Serial2.available() && n < sizeof(buf)) buf[n++] = Serial2.read();
    }
    if (n > 0) {
      Serial.printf(">>> [%d][%s] RESPONDEU! ", baud, c.nome);
      dump(buf, n);
    } else {
      Serial.printf("    [%d][%s] (sem resposta)\n", baud, c.nome);
    }
  }
  Serial2.end();
}

void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println("\n[prober] enviando comandos candidatos p/ a prensa...");
}

void loop() {
  for (int b : BAUDS) probarBaud(b);
  Serial.println("\n--- rodada completa, repetindo em 3s ---");
  delay(3000);
}
