#!/usr/bin/env python3
"""
sniff.py — Engenharia reversa do protocolo serial de uma prensa de concreto.

Roda no PC (idealmente o Windows do lab) ligado a prensa. Abre a porta COM,
mostra cada quadro recebido em HEX + ASCII com timestamp, tenta destacar o
terminador (CR/LF/CRLF) e os numeros candidatos a "carga". Salva tudo em log.

Dependencia:  pip install pyserial

Exemplos:
  # listar portas e tentar identificar conversores USB-Serial (FTDI/CH340/CP2102)
  python sniff.py --list

  # capturar de COM3 a 9600 8N1 e salvar em captura.log
  python sniff.py --port COM3 --baud 9600 --out captura.log

  # se nao souber o baud, varre os mais comuns por alguns segundos cada
  python sniff.py --port COM3 --scan
"""
import argparse, sys, time, re

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("Falta pyserial. Instale com:  pip install pyserial")

CONHECIDOS = {  # VID:PID -> chip (ajuda a achar qual COM e a prensa)
    (0x0403, 0x6001): "FTDI FT232",
    (0x0403, 0x6015): "FTDI FT231X",
    (0x1A86, 0x7523): "CH340",
    (0x10C4, 0xEA60): "CP2102",
    (0x067B, 0x2303): "Prolific PL2303",
}
BAUDS = [9600, 19200, 38400, 57600, 115200, 4800]


def listar():
    portas = list(list_ports.comports())
    if not portas:
        print("Nenhuma porta serial encontrada.")
        return
    print("Portas seriais:")
    for p in portas:
        chip = CONHECIDOS.get((p.vid, p.pid), "")
        vidpid = f"{p.vid:04X}:{p.pid:04X}" if p.vid else "—"
        print(f"  {p.device:8}  {vidpid:10} {chip:16} {p.description}")
    print("\nDica: desconecte o cabo da prensa, rode de novo, e veja qual porta sumiu.")


def termo(linha: bytes) -> str:
    if linha.endswith(b"\r\n"): return "CRLF"
    if linha.endswith(b"\n"):   return "LF"
    if linha.endswith(b"\r"):   return "CR"
    return "?"


def numeros(txt: str):
    return re.findall(r"[-+]?\d+(?:[.,]\d+)?", txt)


def capturar(port, baud, out, segundos=None):
    print(f"Abrindo {port} @ {baud} 8N1 ... (Ctrl+C para parar)")
    fh = open(out, "ab") if out else None
    try:
        ser = serial.Serial(port, baud, bytesize=8, parity="N", stopbits=1, timeout=0.5)
    except Exception as e:
        sys.exit(f"Erro ao abrir {port}: {e}")

    buf = bytearray()
    t_ini = time.time()
    recebeu = 0
    try:
        while True:
            if segundos and time.time() - t_ini > segundos:
                break
            b = ser.read(64)
            if not b:
                continue
            recebeu += len(b)
            buf.extend(b)
            # quebra por CR ou LF, preservando terminador para diagnostico
            while True:
                i = max(buf.find(b"\n"), buf.find(b"\r"))
                if i < 0:
                    break
                linha = bytes(buf[: i + 1]); del buf[: i + 1]
                ts = time.strftime("%H:%M:%S")
                hexs = linha.hex(" ")
                asc = linha.decode("ascii", "replace").rstrip("\r\n")
                nums = numeros(asc)
                marca = f"  <num: {', '.join(nums)}>" if nums else ""
                print(f"[{ts}] {termo(linha):4} | {asc!r}{marca}")
                if fh:
                    fh.write(f"[{ts}] term={termo(linha)} hex={hexs} ascii={asc!r} nums={nums}\n".encode())
    except KeyboardInterrupt:
        pass
    finally:
        ser.close()
        if fh: fh.close()
    return recebeu


def main():
    ap = argparse.ArgumentParser(description="Sniffer serial p/ prensa de concreto")
    ap.add_argument("--list", action="store_true", help="lista portas e chips USB-Serial")
    ap.add_argument("--port", help="porta COM (ex.: COM3 ou /dev/ttyUSB0)")
    ap.add_argument("--baud", type=int, default=9600)
    ap.add_argument("--scan", action="store_true", help="varre bauds comuns")
    ap.add_argument("--out", default="captura.log", help="arquivo de log")
    a = ap.parse_args()

    if a.list or not a.port:
        listar()
        if not a.port:
            return
    if a.scan:
        print("Varredura de baud (5s cada). Onde aparecer ASCII legivel, esse e o baud.")
        for b in BAUDS:
            print(f"\n===== {b} baud =====")
            capturar(a.port, b, None, segundos=5)
        return
    capturar(a.port, a.baud, a.out)


if __name__ == "__main__":
    main()
