// Firmware de TESTE BLE — prova o Bluetooth Low Energy do ESP32 num Android.
//
// O ESP32 anuncia o nome "LabConcreto-BLE" e expoe uma caracteristica que
// NOTIFICA em texto uma curva de ruptura simulada (carga em kN / tensao em MPa),
// igual ao modo de teste do gateway. Use o app "nRF Connect for Mobile" (Android)
// para escanear, conectar e ver os valores mudando ao vivo.
//
// NAO tem WiFi/MQTT aqui — e so o teste de Bluetooth. Para voltar ao gateway:
//   pio run -d gateway-esp32 -t upload

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define DEVICE_NAME   "LabConcreto-BLE"
#define SERVICE_UUID  "a1b2c3d4-0001-1000-8000-00805f9b34fb"
#define CHAR_UUID     "a1b2c3d4-0002-1000-8000-00805f9b34fb"

BLECharacteristic* canal = nullptr;
bool conectado = false;

// corpo de prova 10x20 cm
const double AREA_MM2 = PI * 50.0 * 50.0;
inline double mpa(double kN) { return (kN * 1000.0) / AREA_MM2; }

class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { conectado = true;  Serial.println("[ble] celular conectou"); }
  void onDisconnect(BLEServer* s) override {
    conectado = false; Serial.println("[ble] desconectou — re-anunciando");
    s->startAdvertising();   // volta a aparecer no scan
  }
};

void notificar(const char* txt) {
  if (!canal) return;
  canal->setValue((uint8_t*)txt, strlen(txt));
  if (conectado) canal->notify();
  Serial.printf("[ble] %s\n", txt);
}

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n[ble] iniciando BLE...");

  BLEDevice::init(DEVICE_NAME);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCb());

  BLEService* service = server->createService(SERVICE_UUID);
  canal = service->createCharacteristic(
      CHAR_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  canal->addDescriptor(new BLE2902());          // habilita "subscribe" de notify
  canal->setValue("aguardando ensaio...");
  service->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.printf("[ble] anunciando como \"%s\". Procure no nRF Connect.\n", DEVICE_NAME);
}

// curva de ruptura simulada, nao-bloqueante
void loop() {
  static unsigned long ult = 0;
  static int t = -1;            // -1 = parado entre ensaios
  static double pico = 0;
  const int T = 5000, dt = 200;

  if (millis() - ult < (unsigned long)dt) return;
  ult = millis();

  char buf[64];
  if (t < 0) {                  // comeca novo ensaio
    pico = 200.0 + (esp_random() % 16000) / 100.0;   // ~200-360 kN
    t = 0;
    notificar("INICIO");
    return;
  }
  if (t <= T) {
    double kN = pico * pow((double)t / T, 1.15);
    snprintf(buf, sizeof(buf), "%.1f kN | %.1f MPa", kN, mpa(kN));
    notificar(buf);
    t += dt;
  } else {                      // ruptura + pausa
    snprintf(buf, sizeof(buf), "RUPTURA %.1f kN = %.1f MPa", pico, mpa(pico));
    notificar(buf);
    t = -1;
    delay(2000);                // pausa entre ensaios (ok, fora do ritmo BLE)
  }
}
