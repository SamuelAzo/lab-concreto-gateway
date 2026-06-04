// Copie para config.h e ajuste. config.h esta no .gitignore (nao versionar credenciais).
#pragma once

// ---------- WiFi ----------
#define WIFI_SSID     "SUA_REDE"
#define WIFI_PASS     "SUA_SENHA"

// ---------- MQTT ----------
// Broker publico HiveMQ (PoC, sem TLS na porta 1883). O dashboard usa o mesmo broker
// via WSS:8884 — mesmos topicos, interoperam. Em producao troque por seu broker + TLS:8883.
#define MQTT_HOST     "broker.hivemq.com"
#define MQTT_PORT     1883
#define MQTT_SALA     "topcon-demo"          // prefixo: labconc/<sala>
#define DEVICE_ID     "prensa01"             // identifica esta prensa

// ---------- Serial da prensa (via MAX3232) ----------
#define PRENSA_BAUD   9600                   // descoberto na engenharia reversa (9600/19200/38400)
#define PRENSA_RX_PIN 16                     // GPIO16 <- R1OUT do MAX3232
#define PRENSA_TX_PIN 17                     // GPIO17 -> T1IN do MAX3232
// SERIAL_8N1 e o padrao; ajuste se a prensa usar paridade/stop diferente.

// ---------- Parser generico ----------
// Estrategia simples e robusta: extrai o PRIMEIRO numero de cada linha como carga bruta
// e multiplica por PARSER_ESCALA para obter kN. Ajuste a escala conforme a unidade da
// prensa (ex.: se a prensa manda kgf, 1 kgf = 0.00980665 kN; se manda N, 0.001).
#define PARSER_ESCALA   0.001                // exemplo: prensa em Newtons -> kN
#define DIAM_MM         100.0                // corpo de prova cilindrico 10x20 cm

// Deteccao de ruptura: apos passar de RUPTURA_MIN_KN, se a carga cair abaixo de
// (pico * RUPTURA_QUEDA), considera-se rompido e publica o pico.
#define RUPTURA_MIN_KN  5.0
#define RUPTURA_QUEDA   0.80

// ---------- Modo de teste de bancada ----------
// Com TEST_MODE em 1, o ESP32 gera ensaios SIMULADOS sozinho (sem precisar da
// prensa nem do MAX3232 ligado), a cada TEST_INTERVALO_S segundos. Serve para
// validar WiFi + MQTT: os ensaios aparecem no dashboard do celular.
// Quando for ligar na prensa de verdade, troque TEST_MODE para 0.
#define TEST_MODE        1
#define TEST_INTERVALO_S 15
