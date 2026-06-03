# Estudo técnico — Leitura serial de prensa de concreto e envio para a nuvem

> Estudo de **hardware + software** para ler a porta serial/USB de uma prensa de ensaio de
> rompimento de corpo de prova de concreto, enviar os dados de ruptura para um app na nuvem
> e permitir que a nuvem **peça dados** de volta. Acompanha um PoC funcional (ver [README](../README.md)).

---

## 1. Problema e objetivos

No laboratório, a prensa que rompe o corpo de prova mede a **carga** (célula de carga) e
calcula a **tensão de ruptura** (MPa). Esses valores hoje ficam presos no painel/PC da máquina.
Queremos:

1. **Ler** a saída serial da prensa (RS‑232 na maioria; às vezes USB nativo ou USB‑Serial).
2. **Enviar** os dados (carga máxima, MPa, curva carga×tempo, identificação do CP) para um **app na nuvem**.
3. **Pedir dados** sob demanda (a nuvem solicita uma leitura/identificação ou dispara um ensaio).

**Restrições reais do laboratório:**
- A **marca/modelo varia** (EMIC/Instron, Contenco/Pavitest, Forney, Matest, Controls…) → o protocolo precisa ser tratado de forma **genérica + engenharia reversa**.
- O PC do lab fica **atrás de NAT**, sem IP público → a nuvem não consegue abrir conexão de entrada.
- **Internet instável** → precisa de buffer offline e reconexão.
- Pode não haver PC ao lado da prensa, ou ele já estar ocupado pelo software do fabricante.

---

## 2. Panorama das prensas e suas saídas seriais

| Fabricante / linha | Interface típica | Baud comum | Modo de saída |
|---|---|---|---|
| EMIC / Instron | Serial + HMI, integra LIMS | 9600 | streaming (carga/extensão em tempo real) |
| Contenco / **Pavitest** | RS‑232 + software Pavitest | 9600 | streaming + valor final |
| Forney / ForneyLink | HMI touchscreen, 2 vias c/ LIMS | 19200 | streaming |
| Matest / Controls (IT‑TECH) | RS‑232 / unidade de controle | 9600 | streaming/proprietário |
| Time Group | Serial / Modbus / CAN | variável | híbrido (até ~500 Hz) |

Três **modos de saída** a considerar (o gateway precisa lidar com todos):

- **Push / streaming** — a máquina envia continuamente durante o ensaio, ex.:
  `LOAD: 12345 N`<CR> … até a ruptura. É o caso mais comum em célula de carga integrada.
- **Query / resposta** — o host pergunta, a máquina responde, ex.: `READ?`<CR> → `+12345 g`<CR>.
  Comum em condicionadores de sinal / células digitais.
- **Só imprime** — a prensa manda os dados para uma **impressora serial**; não há "porta de dados".
  Aqui é preciso **interceptar** o fluxo (ver §4).

> Em todos, o dado costuma ser **ASCII** terminado por **CR (0x0D)**, **LF (0x0A)** ou **CRLF**,
> com um ou mais números por linha (carga, tensão, tempo).

---

## 3. Camada física: RS‑232 vs USB vs conversores

- **RS‑232 (DB‑9):** níveis **±12 V**, pinos essenciais **TX (3)**, **RX (2)**, **GND (5)**.
  Não pode ligar direto em microcontrolador 3,3 V — precisa de tradutor de nível (**MAX3232**).
- **USB nativo:** prensas modernas expõem uma interface USB‑CDC; aparecem como `COMx` direto.
- **Conversores USB‑Serial:** quando o PC não tem DB‑9, usa‑se um adaptador. O **chip** importa:

| Chip | VID:PID | Observação |
|---|---|---|
| FTDI FT232 | `0403:6001` | **mais confiável**, driver estável — preferir |
| CH340 | `1A86:7523` | barato, ok p/ hobby; problemas após updates do Windows |
| CP2102 | `10C4:EA60` | bom, requer driver Silicon Labs |
| Prolific PL2303 | `067B:2303` | muitos clones com driver problemático — evitar |

**Identificar qual `COMx` é a prensa:** abra o *Gerenciador de Dispositivos* → *Portas (COM & LPT)*,
desconecte o cabo e veja qual porta some; ou use `serial-discovery/sniff.py --list`, que casa o
**VID:PID** com a tabela acima.

---

## 4. Procedimento de engenharia reversa do protocolo

Como a prensa varia, este é o passo mais importante. Use [`serial-discovery/sniff.py`](../serial-discovery/sniff.py):

1. **Achar a porta:** `python sniff.py --list` (mostra chip e VID:PID).
2. **Achar o baud:** `python sniff.py --port COM3 --scan` — varre 9600/19200/38400/57600/115200/4800
   por 5 s cada. O baud certo é onde aparece **ASCII legível** (e não lixo).
3. **Capturar um ensaio real:** `python sniff.py --port COM3 --baud 9600 --out captura.log`
   e rompa um CP. O log traz, por quadro: **terminador** (CR/LF/CRLF), **HEX**, **ASCII** e os
   **números candidatos** (`<num: ...>`) — normalmente a carga e/ou a tensão.
4. **Isolar o campo de carga:** observe qual número cresce monotonicamente até cair na ruptura.
   Anote a **unidade** (N, kgf, kN, tf) e a posição na linha.
5. **Traduzir em parâmetros do parser** (usados igualmente no firmware e no simulador):
   - `PRENSA_BAUD`, terminador, e `PARSER_ESCALA` (fator p/ converter o número bruto em **kN**:
     N→×0.001, kgf→×0.00980665, tf→×9.80665, kN→×1).

**Quando a porta já está ocupada ou a máquina "só imprime":**
- Use um **sniffer de porta** com driver de filtro (HHD Serial Port Monitor, SerialTool) que lê a
  COM **sem** tomar a porta do software do fabricante; ou um **par de COM virtual** (com0com) que
  duplica o fluxo: o software original continua "imprimindo" e o gateway lê a cópia.
- Valide o parser com dado real **sem hardware**: `python replay.py captura.log --escala 0.001`
  gera `curva.csv`, e `node gateway-simulator/simulator.js --replay curva.csv` reemite por MQTT.

---

## 5. Arquitetura recomendada — Gateway ESP32 ⭐

```
 Prensa RS-232 (±12V)
        │  TX/RX/GND
   [ MAX3232 ]                    (tradutor de nível ±12V ⇄ 3.3V)
        │  R1OUT→GPIO16 (RX) | T1IN←GPIO17 (TX) | GND comum
   [ ESP32 ] ── WiFi ──► MQTT broker ──► cloud-api ──► dashboard
        ▲                                                  (celular)
        └────────── commands (READ?/START) ◄──────────────┘
```

**Por que um gateway dedicado:**
- Funciona **mesmo sem PC** ao lado da prensa; não disputa a porta com o software do fabricante.
- **Barato** (~R$ 70–130) e isolado — uma "caixinha" por prensa.
- WiFi resolve o NAT (conexão **de saída**); MQTT dá o caminho de volta para "pedir dados".
- Buffer offline em **NVS** (flash) e **OTA** para atualizar firmware.

**Lista de materiais (BOM) e ligação:**

| Item | Detalhe |
|---|---|
| ESP32 DevKit V1 (WROOM‑32) | 3,3 V, WiFi, 2 UARTs livres |
| Módulo **MAX3232** + DB9 fêmea | converte RS‑232 ↔ TTL 3,3 V |
| Fonte 5 V (USB) | alimenta o ESP32 |

Ligação do MAX3232 ↔ ESP32: `R1OUT → GPIO16 (RX)`, `T1IN ← GPIO17 (TX)`, **GND comum**,
`VCC = 3V3`. Lado RS‑232 do módulo no DB9 da prensa (TX/RX/GND).
⚠️ **Nunca** ligar a RS‑232 (±12 V) direto nos GPIOs — queima o ESP32. O MAX3232 é obrigatório.

Firmware: [`gateway-esp32/src/main.cpp`](../gateway-esp32/src/main.cpp). Parser genérico (extrai o
primeiro número da linha × escala → kN), detecção de ruptura (queda abaixo de fração do pico),
publish/subscribe MQTT e buffer NVS do último resultado.

---

## 6. Alternativas comparadas

| Critério | **Gateway ESP32** (recomendado) | Agente desktop (Node/Python/.NET) | Web Serial API (navegador) |
|---|---|---|---|
| Instalação | grava firmware 1× | serviço Windows no PC | nenhuma (Chrome) |
| Funciona sem PC | ✅ | ❌ | ❌ |
| Buffer offline | ✅ NVS | ✅ SQLite/fila | ❌ |
| Roda em background | ✅ | ✅ serviço | ❌ (aba aberta) |
| Máquina "só USB"/driver proprietário | ⚠️ (precisa RS‑232/TTL) | ✅ melhor caso | ⚠️ só Chromium |
| "Pedir dados" sob NAT | ✅ MQTT | ✅ MQTT/polling | ⚠️ só polling |
| Custo | ~R$ 100 hardware | R$ 0 (usa o PC) | R$ 0 |

**Quando escolher cada um:**
- **Agente desktop** se a prensa só fala **USB nativo** ou exige driver/SDK do fabricante no Windows,
  ou se já há um PC dedicado ligado à máquina. (Node + `serialport` como serviço NSSM é o caminho mais robusto.)
- **Web Serial** para uma demo rápida ou uso pontual, sem instalar nada (só Chrome/Edge desktop, HTTPS).
- **Gateway ESP32** como padrão de produção pela independência do PC e robustez.

---

## 7. Contrato da API (app novo dedicado)

App em [`cloud-api/`](../cloud-api/) (Express + SQLite + MQTT). Modelo de dados:

- **`ensaios`** — `id, device, diam_mm, status(aberto|finalizado), pico_kN, tensao_MPa, started_at, finished_at`
- **`leituras`** — `id, ensaio_id, t_ms, carga_kN, tensao_MPa, evento, ts`

Endpoints REST:

| Método | Rota | Função |
|---|---|---|
| `GET` | `/api/ensaios` | lista os ensaios |
| `GET` | `/api/ensaios/:id` | ensaio + curva (leituras) |
| `POST` | `/api/ensaios` | abre ensaio manualmente |
| `POST` | `/api/ensaios/:id/leituras` | adiciona leitura (streaming/final) |
| `POST` | `/api/dispositivos/:id/comando` | **pedir dados**: publica `READ?`/`*IDN?`/`START`/`STOP` no MQTT |
| `GET` | `/api/stream` | SSE p/ o dashboard atualizar ao vivo |

A ingestão é automática: a `cloud-api` assina `readings/+`, abre um ensaio no `inicio`,
acumula `streaming` e finaliza com o pico no `ruptura` (ver [`mqtt-bridge.js`](../cloud-api/src/mqtt-bridge.js)).

---

## 8. Comunicação bidirecional sob NAT

O lab está atrás de NAT — a nuvem **não** consegue iniciar conexão para lá. **MQTT** resolve:
o gateway abre uma conexão **de saída** e fica `subscribe` em `commands/<device>`; a nuvem só
**publica** nesse tópico e o comando chega com latência baixa, sem abrir porta no roteador do lab.

| Abordagem | Latência | Bidirecional sob NAT | Complexidade |
|---|---|---|---|
| **MQTT** (escolhido) | baixa (<100 ms) | ✅ nativo | média (precisa broker) |
| HTTP polling | 5–30 s | ✅ (GET periódico) | baixa, mas ineficiente |
| WebSocket reverso/túnel | baixa | ✅ via túnel | alta (ngrok etc.) |

Fluxo "pedir dados": `POST /api/dispositivos/prensa01/comando {cmd:"READ?"}` → broker →
gateway recebe → responde publicando uma leitura `evento:"resposta"` → dashboard mostra.

---

## 9. Confiabilidade

- **Buffer offline:** ESP32 grava o último resultado de ruptura em **NVS**; reenvia ao reconectar.
  No agente desktop, usar fila em SQLite/JSONL.
- **Reconexão:** WiFi e MQTT com retry/backoff (já no firmware e nos clientes Node).
- **Idempotência:** ensaio agrupado por `device` + `inicio`; o backend evita duplicar finalizações.
- **QoS:** para produção, publicar ruptura com **QoS 1** (entrega garantida).
- **Identificação da prensa:** `device` fixo por gateway; no PC, casar VID:PID (§3).

---

## 10. Segurança

- **PoC:** broker **público sem autenticação** (`broker.hivemq.com`) — só para demonstração.
- **Produção:**
  - Broker próprio (Mosquitto/EMQX/HiveMQ Cloud) com **usuário/senha por dispositivo** e **TLS** (MQTT 8883; WSS 8884).
  - Tópicos por **tenant/sala** com ACL (cada prensa só publica no seu tópico).
  - API atrás de **HTTPS**; credenciais do firmware em `config.h` (fora do git — já no `.gitignore`),
    idealmente provisionadas por dispositivo, **nunca** em texto compartilhado.

---

## 11. Custos e roadmap

**Custo do PoC:** ~R$ 0 de software (broker público/local grátis) + ~R$ 100 de hardware por prensa (ESP32 + MAX3232).

**Roadmap:**
1. Engenharia reversa da prensa real do lab (§4) e ajuste do `PARSER_ESCALA`.
2. Broker próprio com TLS + auth e persistência (trocar `MQTT_URL`/`TOPIC_PREFIX`).
3. Deploy da `cloud-api` (Render/Railway/AWS Lightsail) com banco persistente.
4. Cadastro do **corpo de prova** (lote, idade, dimensões) e cálculo conforme **NBR 7680‑1 / ASTM C39**.
5. Múltiplas prensas e relatórios.
6. **Integração futura com o TopconCRM** (API existente em `https://35-168-164-226.nip.io`): a
   `cloud-api` pode encaminhar o resultado de ruptura para um endpoint do CRM, associando ao
   cliente/obra — mantendo este serviço como coletor dedicado e o CRM como destino de negócio.

---

### Referências
Prensas e protocolo: Instron/EMIC, Contenco/Pavitest, Forney, Matest/Controls. Serial/USB: docs FTDI,
Silicon Labs CP2102, WCH CH340; padrão ASCII CR/LF. Bridge: Web Serial API (MDN/Chrome), Node
`serialport`, `pyserial`, ESP32 `HardwareSerial`/`PubSubClient`; MQTT sob NAT. (Links no histórico de pesquisa do projeto.)
