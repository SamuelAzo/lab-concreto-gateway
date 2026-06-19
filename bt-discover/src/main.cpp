// Descoberta Bluetooth Classico: lista nome + MAC dos dispositivos visiveis.
// Use para achar o leitor de codigo de barras (deve estar em modo SPP e visivel).
// Repete a varredura a cada ~12 s.
#include <Arduino.h>
#include "BluetoothSerial.h"

BluetoothSerial SerialBT;

void varrer() {
  Serial.println("\n[disc] procurando dispositivos Bluetooth (10s)...");
  BTScanResults* r = SerialBT.discover(10000);
  if (!r) { Serial.println("[disc] discover() retornou null"); return; }
  int n = r->getCount();
  Serial.printf("[disc] %d dispositivo(s):\n", n);
  for (int i = 0; i < n; i++) {
    BTAdvertisedDevice* d = r->getDevice(i);
    Serial.printf("   %2d) nome=\"%s\"  MAC=%s\n",
                  i, d->getName().c_str(), d->getAddress().toString().c_str());
  }
  Serial.println("[disc] >>> ache o leitor na lista (nome tipo 'BarCode'/'Netum'/'Scanner') <<<");
}

void setup() {
  Serial.begin(115200);
  delay(300);
  SerialBT.begin("ESP32-Discover", true);   // master, so para inquirir
  Serial.println("[disc] iniciado. Coloque o leitor em SPP e visivel.");
  varrer();
}

void loop() {
  delay(2000);
  varrer();
}
