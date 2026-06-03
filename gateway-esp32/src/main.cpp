// Gateway ESP32 — le a serial RS-232 da prensa (via MAX3232) e publica os dados de
// ruptura por MQTT, no mesmo contrato do simulator.js e do dashboard.
//
// Fluxo:  Prensa RS-232  ->  MAX3232  ->  ESP32 UART2 (GPIO16/17)
//                                            |  parser generico
//                                            v
//                         WiFi -> MQTT -> labconc/<sala>/readings/<device>
//                         assina        <- labconc/<sala>/commands/<device>  (READ?, *IDN?, START)
//
// IMPORTANTE: a prensa RS-232 trabalha em +-12V; o ESP32 e 3.3V. O modulo MAX3232 e
// OBRIGATORIO entre eles. Nao ligue a RS-232 direto nos GPIOs.

#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include "config.h"   // copie de config.example.h

WiFiClient net;
PubSubClient mqtt(net);
Preferences nvs;

String topReadings, topCommands;
char clientId[32];

// estado do ensaio
double picoKN = 0.0;
bool emEnsaio = false;
unsigned long t0 = 0;
double ultimaCargaKN = 0.0;

const double AREA_MM2 = PI * (DIAM_MM / 2.0) * (DIAM_MM / 2.0);
inline double mpaFromKN(double kN) { return (kN * 1000.0) / AREA_MM2; }

// ---------- buffer offline simples (NVS) ----------
// Guarda apenas o ULTIMO resultado de ruptura nao enviado; ao reconectar, reenvia.
void salvarPendente(double kN) {
  nvs.begin("gw", false);
  nvs.putDouble("pend_kN", kN);
  nvs.putBool("pend", true);
  nvs.end();
}
void enviarPendente() {
  nvs.begin("gw", false);
  if (nvs.getBool("pend", false)) {
    double kN = nvs.getDouble("pend_kN", 0);
    publishRuptura(kN, true);
    nvs.putBool("pend", false);
  }
  nvs.end();
}

// ---------- publish helpers ----------
void publishReading(const char* evento, double kN, unsigned long t_ms) {
  JsonDocument doc;
  doc["device"] = DEVICE_ID;
  doc["evento"] = evento;
  doc["diam_mm"] = DIAM_MM;
  doc["t_ms"] = t_ms;
  doc["carga_kN"] = round(kN * 100) / 100.0;
  doc["tensao_MPa"] = round(mpaFromKN(kN) * 100) / 100.0;
  char buf[200];
  size_t n = serializeJson(doc, buf);
  ultimaCargaKN = kN;
  mqtt.publish(topReadings.c_str(), buf, n);
}
void publishRuptura(double kN, bool reenvio) {
  if (!mqtt.connected()) { salvarPendente(kN); return; }
  publishReading("ruptura", kN, millis() - t0);
  Serial.printf("[gw] RUPTURA %.1f kN = %.1f MPa%s\n", kN, mpaFromKN(kN), reenvio ? " (reenvio)" : "");
}

// ---------- parser generico: extrai o primeiro numero da linha ----------
bool extrairNumero(const String& linha, double& out) {
  int i = 0, n = linha.length();
  while (i < n && !(isDigit(linha[i]) || linha[i] == '-' || linha[i] == '+' || linha[i] == '.')) i++;
  if (i >= n) return false;
  int j = i;
  while (j < n && (isDigit(linha[j]) || linha[j] == '.' || linha[j] == '-' || linha[j] == '+')) j++;
  out = linha.substring(i, j).toFloat();
  return true;
}

void processarLinha(const String& linha) {
  double bruto;
  if (!extrairNumero(linha, bruto)) return;
  double kN = bruto * PARSER_ESCALA;

  if (!emEnsaio && kN > RUPTURA_MIN_KN) {       // comecou a carregar
    emEnsaio = true; picoKN = 0; t0 = millis();
    publishReading("inicio", 0, 0);
  }
  if (emEnsaio) {
    if (kN > picoKN) picoKN = kN;
    publishReading("streaming", kN, millis() - t0);
    // ruptura: caiu abaixo de fracao do pico depois de ter carregado
    if (picoKN > RUPTURA_MIN_KN && kN < picoKN * RUPTURA_QUEDA) {
      publishRuptura(picoKN, false);
      emEnsaio = false; picoKN = 0;
    }
  }
}

// ---------- MQTT callback (nuvem -> gateway) ----------
void onCommand(char* topic, byte* payload, unsigned int len) {
  JsonDocument doc;
  if (deserializeJson(doc, payload, len)) return;
  const char* cmd = doc["cmd"] | "";
  Serial.printf("[gw] comando: %s\n", cmd);
  if (strcmp(cmd, "READ?") == 0) {
    publishReading("resposta", ultimaCargaKN, millis() - t0);
  } else if (strcmp(cmd, "*IDN?") == 0) {
    JsonDocument d; d["device"] = DEVICE_ID; d["evento"] = "idn"; d["modelo"] = "ESP32-Gateway v0.1";
    char buf[160]; size_t n = serializeJson(d, buf); mqtt.publish(topReadings.c_str(), buf, n);
  } else if (strcmp(cmd, "START") == 0 || strcmp(cmd, "STOP") == 0 || strcmp(cmd, "TARE") == 0) {
    // encaminha o comando ASCII para a prensa (se ela aceitar query/resposta)
    Serial2.print(cmd); Serial2.print("\r");
  }
}

void conectarWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("[gw] WiFi");
  while (WiFi.status() != WL_CONNECTED) { delay(400); Serial.print("."); }
  Serial.printf(" OK  IP=%s\n", WiFi.localIP().toString().c_str());
}

void conectarMQTT() {
  while (!mqtt.connected()) {
    Serial.print("[gw] MQTT...");
    if (mqtt.connect(clientId)) {
      Serial.println(" conectado");
      mqtt.subscribe(topCommands.c_str());
      enviarPendente();
    } else {
      Serial.printf(" falhou (rc=%d), retry 2s\n", mqtt.state());
      delay(2000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  Serial2.begin(PRENSA_BAUD, SERIAL_8N1, PRENSA_RX_PIN, PRENSA_TX_PIN);

  snprintf(clientId, sizeof(clientId), "gw-%s-%04X", DEVICE_ID, (uint16_t)(ESP.getEfuseMac() & 0xFFFF));
  String base = String("labconc/") + MQTT_SALA;
  topReadings = base + "/readings/" + DEVICE_ID;
  topCommands = base + "/commands/" + DEVICE_ID;

  conectarWiFi();
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setBufferSize(512);
  mqtt.setCallback(onCommand);
  conectarMQTT();
  Serial.printf("[gw] pronto. lendo prensa @ %d baud, publicando em %s\n", PRENSA_BAUD, topReadings.c_str());
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) conectarWiFi();
  if (!mqtt.connected()) conectarMQTT();
  mqtt.loop();

  // le linhas da prensa terminadas por CR ou LF
  static String linha;
  while (Serial2.available()) {
    char c = Serial2.read();
    if (c == '\r' || c == '\n') {
      if (linha.length()) { processarLinha(linha); linha = ""; }
    } else if (linha.length() < 120) {
      linha += c;
    }
  }
}
