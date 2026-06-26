# Engenharia reversa das prensas (protocolos serial)

Registro do que foi decodificado em campo, com a configuração para o gateway.

## DIGI-TRON

- **Serial:** 9600 8N1
- **Quadro:** `X######.` + CR (ex.: `D012345.`), `X`=`D` (estável) / `@` (movendo)
- **Unidade:** kgf → kN com `PARSER_ESCALA = 0.00980665`
- Lê passivo (streaming), sem handshake. Decodificada via USB‑serial direto.

## DIGITEC  ✅ (decodificada em campo)

- **Serial:** 9600 8N1
- **Transmissão:** **streaming contínuo enquanto a prensa aplica carga** (para quando
  ociosa). Não precisa de comando/tecla — a prensa manda sozinha.
- **Quadro:** `$ALL  <carga>   <deslocamento>  <flag>` + CR (`\r`)
  - Exemplo de carga subindo:
    ```
    $ALL    -1.547     0.662 0
    $ALL   322.426    96.500 0     <- pico (logo antes da ruptura)
    $ALL   286.000    99.000 0     <- carga despencou = CP rompeu
    ```
  - **1º número = CARGA, já em kN.** Sobe e **despenca** na ruptura. (medição real: **322.4 kN**)
  - **2º número = deslocamento/curso.** Sobe sempre e **não cai** → ignorar.
  - **3º número = flag** de status (visto `0`).
- **Config no gateway:** `PRENSA_BAUD 9600`, `PARSER_ESCALA 1.0` (o parser genérico
  pega o 1º número = a carga). Detecção de ruptura por pico + queda já funciona.

### ⚠️ Handshake — essencial para o ESP32 + MAX3232

A DIGITEC **só transmite quando "vê" o PC pronto** (linhas de controle RS‑232 ativas).

- Um **FTDI / USB‑RS232** (ou o PC do fabricante) liga DTR/RTS automaticamente → funciona de cara.
- O **MAX3232 de 3 fios** (só TX/RX/GND) **NÃO** tem essas linhas → a prensa fica em idle e
  **não manda nada** (foi o que travou os primeiros testes).

**Solução para o ESP32:** fazer o **loopback de handshake no DB9 da prensa**:
- **pino 7 ↔ pino 8** (RTS ↔ CTS)
- **pino 4 ↔ pino 6** (DTR ↔ DSR)

Mantém TX/RX/GND (2/3/5) indo para o MAX3232 e adiciona esses dois curtos. Aí a prensa
"vê o OK" e dispara o stream.

### Leitura rápida via FTDI (PC/Mac), sem ESP32

```python
import serial, re
p = serial.Serial('/dev/cu.usbserial-XXXX', 9600, timeout=0.3)
p.setDTR(True); p.setRTS(True)          # handshake que a DIGITEC espera
raw = b''
while True:
    raw += p.read(256)
    *linhas, raw = raw.split(b'\r')
    for ln in linhas:
        m = re.match(rb'\$ALL\s+(-?\d+\.\d+)', ln)
        if m: print('carga kN =', float(m.group(1)))   # 1o campo = carga
```

## Diagnóstico de hardware: o caso do MAX3232 "ruim"

Durante a saga, nenhum dado limpo chegava da DIGITEC. O culpado **não era a prensa** — era o
**MAX3232** corrompendo os bytes (alimentação/contato marginal de VCC/GND).

**Teste de loopback** (isola o conversor do ESP32):
1. Firmware envia `LOOPBACK-OK-N` na Serial2 TX e lê de volta na RX.
2. **Pelo MAX3232:** curto pino 2↔3 do DB9 → se voltar limpo, MAX3232 OK.
3. **Só ESP32:** liga GPIO17↔GPIO16 direto (sem MAX3232) → se voltar limpo, ESP32 OK.

Resultado: ESP32 sempre limpo; MAX3232 voltava corrompido até **firmar VCC=3V3 e GND** —
depois passou a voltar limpo. Moral: **VCC do MAX3232 tem que estar firme no 3V3** do ESP32.

> Ferramentas de diagnóstico usadas estão em `solotest-sniffer/` (sniffer/scan de baud/
> auto‑baud/loopback) e `press-prober/` (envio ativo de comandos).
