#!/usr/bin/env python3
"""
replay.py — Converte um log capturado pelo sniff.py em pares "t_ms,carga_kN"
que o gateway-simulator consegue reproduzir (node simulator.js --replay arquivo).

Assim voce valida o parser/curva com DADO REAL da prensa, sem o hardware ligado.

Uso:
  python replay.py captura.log --escala 0.001 --out curva.csv
    --escala: fator p/ converter o numero bruto da prensa em kN
              (ex.: prensa em Newtons -> 0.001 ; em kgf -> 0.00980665)
"""
import argparse, re, sys

NUM = re.compile(r"nums=\[([^\]]*)\]")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--escala", type=float, default=0.001)
    ap.add_argument("--out", default="curva.csv")
    a = ap.parse_args()

    linhas = open(a.log, encoding="utf-8", errors="replace").read().splitlines()
    pontos, t = [], 0
    for ln in linhas:
        m = NUM.search(ln)
        if not m or not m.group(1).strip():
            continue
        primeiro = m.group(1).split(",")[0].strip().strip("'\"").replace(",", ".")
        try:
            kN = float(primeiro) * a.escala
        except ValueError:
            continue
        pontos.append((t, round(kN, 2)))
        t += 120  # assume ~120 ms entre quadros; ajuste se souber a taxa real

    if not pontos:
        sys.exit("Nenhum numero extraido. Confira o log / a regex nums=[...].")

    with open(a.out, "w") as f:
        for t_ms, kN in pontos:
            f.write(f"{t_ms},{kN}\n")
    pico = max(k for _, k in pontos)
    print(f"OK: {len(pontos)} pontos -> {a.out}. Pico ~{pico} kN.")
    print(f"Reproduza:  node ../gateway-simulator/simulator.js --replay {a.out} --device prensa-real")


if __name__ == "__main__":
    main()
