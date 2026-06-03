# Lab Concreto Gateway 🧱

Ler a porta **serial RS‑232 / USB** de uma **prensa de ensaio de rompimento de corpo de prova de concreto** e levar os dados de ruptura (carga, MPa, curva carga×tempo) para um **app na nuvem** — com a nuvem podendo **pedir dados** de volta.

PoC completo: gateway de hardware (ESP32), simulador para testar sem hardware, app dedicado na nuvem (Node + SQLite) e um dashboard que abre **direto no celular**.

> 📱 **Teste agora no celular:** https://samuelazo.github.io/lab-concreto-gateway/
> Toque em **Simular ensaio** e veja a curva de ruptura ao vivo. Abra a mesma URL em dois aparelhos para ver o pub/sub na nuvem.

📄 **Estudo técnico completo:** [`docs/ESTUDO.md`](docs/ESTUDO.md)

---

## Arquitetura

```
 Prensa RS-232 (±12V)
        │
   [ MAX3232 ]            ← converte ±12V ⇄ 3.3V (OBRIGATÓRIO)
        │  GPIO16/17
   [ ESP32 ] ── WiFi ──► MQTT broker ──► cloud-api (Node+SQLite) ──► dashboard
        ▲                  (HiveMQ /                                  (GitHub Pages
        └── commands ──────  Mosquitto)  ◄── "pedir dados" (READ?) ──   ou local)
```

Tudo conversa por **MQTT** com o mesmo contrato de tópicos, então simulador, ESP32 e dashboard são intercambiáveis:

| Tópico | Quem publica | Quem assina |
|---|---|---|
| `labconc/<sala>/readings/<device>` | gateway / simulador | dashboard, cloud-api |
| `labconc/<sala>/commands/<device>` | nuvem / dashboard | gateway / simulador |

Payload de leitura (JSON):
```json
{ "device":"prensa01", "evento":"streaming|inicio|ruptura|resposta",
  "diam_mm":100, "t_ms":1500, "carga_kN":182.4, "tensao_MPa":23.2 }
```

---

## Componentes

| Pasta | O que é |
|---|---|
| [`docs/`](docs/) | Dashboard (GitHub Pages) + [estudo técnico](docs/ESTUDO.md) |
| [`gateway-esp32/`](gateway-esp32/) | Firmware PlatformIO — lê a prensa via MAX3232 e publica por MQTT |
| [`gateway-simulator/`](gateway-simulator/) | Emula o ESP32 em Node — testa tudo **sem hardware** |
| [`cloud-api/`](cloud-api/) | App dedicado: Express + SQLite + MQTT (REST + dashboard) |
| [`serial-discovery/`](serial-discovery/) | `sniff.py` / `replay.py` — engenharia reversa do protocolo da prensa |
| `docker-compose.yml` | Sobe Mosquitto + cloud-api local |

---

## Como rodar

### Opção A — só o celular (mais rápido)
Abra https://samuelazo.github.io/lab-concreto-gateway/ e toque em **Simular ensaio**. Pronto.

### Opção B — simulador no PC publicando para o broker público
```bash
cd gateway-simulator
npm install
node simulator.js --device prensa01 --sala topcon-demo --loop 15
```
Abra o dashboard (mesma `sala`) no celular e veja os ensaios chegando a cada 15 s.

### Opção C — PoC 100% local (broker + app dedicado)
```bash
docker compose up -d          # Mosquitto + cloud-api em http://localhost:3000
# simulador apontando para o broker local:
MQTT_URL=mqtt://localhost:1883 node gateway-simulator/simulator.js --device prensa01
```
Dashboard local em `http://localhost:3000` (lê do SQLite via REST).
Pedir dados (nuvem → gateway):
```bash
curl -X POST http://localhost:3000/api/dispositivos/prensa01/comando \
  -H 'Content-Type: application/json' -d '{"cmd":"READ?"}'
```

### Opção D — hardware real no lab
1. Descubra o protocolo da prensa: `python serial-discovery/sniff.py --port COM3 --scan`.
2. Ajuste `gateway-esp32/include/config.h` (copie de `config.example.h`): WiFi, baud, `PARSER_ESCALA`.
3. `cd gateway-esp32 && pio run -t upload`.
4. Ligue **Prensa → MAX3232 → ESP32 (GPIO16/17, GND comum)** e abra o dashboard.

---

## Hardware (onde comprar)

**Recomendado — gateway (~R$ 70–130):**
- ESP32 DevKit V1 (WROOM‑32) — FilipeFlop / Eletrogate / Usinainfo / RoboCore / Mercado Livre
- Módulo **MAX3232** RS232↔TTL com DB9 fêmea (chip MAX3232, **não** MAX232)
- Fonte USB 5V + cabo serial DB9 conforme a prensa

**Alternativa — ler direto no PC (~R$ 40–130):**
- Cabo USB↔RS232 com chip **FTDI FT232** (ex.: StarTech ICUSB232V2, Trendnet TU‑S9). Evite clones PL2303/CH340.

⚠️ A RS‑232 da prensa é **±12 V** e o ESP32 é **3,3 V** — o **MAX3232 é obrigatório**; ligar direto queima a placa.

---

## Aviso

PoC sobre **broker público sem autenticação** — ótimo para demonstrar, **não** para dado sensível. O caminho de produção (broker próprio com TLS/usuário, persistência) está descrito no [estudo](docs/ESTUDO.md) e a `cloud-api` já está pronta para isso.
