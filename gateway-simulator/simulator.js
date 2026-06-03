#!/usr/bin/env node
// Simulador do gateway ESP32: gera uma curva de ruptura realista e publica por MQTT,
// exatamente no mesmo contrato (topicos/payload) que o firmware real usa.
// Tambem assina commands/<device> e responde a READ?/*IDN?/START.
//
// Uso:
//   node simulator.js --device prensa01 --sala topcon-demo --loop 0
//   node simulator.js --replay ../serial-discovery/captura.log
//
// Sem flags, publica UM ensaio e fica ouvindo comandos.

import mqtt from 'mqtt';
import { readFileSync } from 'node:fs';

const args = parseArgs(process.argv.slice(2));
const SALA   = args.sala   || process.env.SALA   || 'topcon-demo';
const DEVICE = args.device || process.env.DEVICE || 'prensa01';
const BROKER = args.broker || process.env.MQTT_URL || 'wss://broker.hivemq.com:8884/mqtt';
const PREFIX = `labconc/${SALA}`;
const LOOP_S = args.loop !== undefined ? Number(args.loop) : null; // intervalo entre ensaios automaticos (s); null = so 1

const DIAM_MM = 100;
const AREA_MM2 = Math.PI * (DIAM_MM / 2) ** 2;
const mpa = (kN) => +(((kN * 1000) / AREA_MM2)).toFixed(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let lastReading = { device: DEVICE, carga_kN: 0, tensao_MPa: 0, t_ms: 0, evento: 'idle' };
let rodando = false;

const client = mqtt.connect(BROKER, { clientId: 'sim_' + Math.random().toString(16).slice(2, 8), reconnectPeriod: 2000 });

client.on('connect', async () => {
  console.log(`[sim] conectado em ${BROKER}`);
  console.log(`[sim] device=${DEVICE} sala=${SALA} -> publica em ${PREFIX}/readings/${DEVICE}`);
  client.subscribe(`${PREFIX}/commands/${DEVICE}`);
  client.subscribe(`${PREFIX}/commands/+`); // tambem responde a broadcast simples

  if (args.replay) { await replay(args.replay); return; }

  await ensaio();
  if (LOOP_S && LOOP_S > 0) {
    console.log(`[sim] modo loop: novo ensaio a cada ${LOOP_S}s`);
    setInterval(() => { if (!rodando) ensaio(); }, LOOP_S * 1000);
  } else {
    console.log('[sim] ensaio publicado. Ouvindo comandos (READ?/START). Ctrl+C para sair.');
  }
});
client.on('error', (e) => console.error('[sim] erro:', e.message));

client.on('message', (topic, payload) => {
  let c; try { c = JSON.parse(payload.toString()); } catch { return; }
  const cmd = c.cmd;
  console.log(`[sim] comando recebido: ${cmd}`);
  if (cmd === 'READ?') {
    pub({ ...lastReading, device: DEVICE, evento: 'resposta' });
  } else if (cmd === '*IDN?') {
    pub({ device: DEVICE, evento: 'idn', modelo: 'GatewaySim v0.1', diam_mm: DIAM_MM });
  } else if (cmd === 'START') {
    if (!rodando) ensaio();
  }
});

function pub(r) {
  lastReading = r;
  client.publish(`${PREFIX}/readings/${r.device || DEVICE}`, JSON.stringify(r));
}

async function ensaio() {
  rodando = true;
  const fck = 20 + Math.random() * 25;                         // alvo 20-45 MPa
  const picoKN = +(((fck * AREA_MM2) / 1000) * (0.95 + Math.random() * 0.12)).toFixed(2);
  const T = 5.0, dt = 0.15;
  console.log(`[sim] iniciando ensaio (alvo ~${fck.toFixed(1)} MPa, pico ~${picoKN.toFixed(0)} kN)`);

  pub({ device: DEVICE, evento: 'inicio', diam_mm: DIAM_MM, t_ms: 0, carga_kN: 0, tensao_MPa: 0 });
  let t = 0;
  while (t < T) {
    const frac = t / T;
    const kN = +(picoKN * Math.pow(frac, 1.15) * (1 + (Math.random() - 0.5) * 0.02)).toFixed(2);
    pub({ device: DEVICE, evento: 'streaming', diam_mm: DIAM_MM, t_ms: Math.round(t * 1000), carga_kN: kN, tensao_MPa: mpa(kN) });
    await sleep(dt * 1000);
    t += dt;
  }
  pub({ device: DEVICE, evento: 'ruptura', diam_mm: DIAM_MM, t_ms: Math.round(T * 1000), carga_kN: picoKN, tensao_MPa: mpa(picoKN) });
  console.log(`[sim] RUPTURA: ${picoKN.toFixed(1)} kN = ${mpa(picoKN)} MPa`);
  for (const f of [0.4, 0.15, 0.05]) {
    await sleep(120);
    const kN = +(picoKN * f).toFixed(2);
    pub({ device: DEVICE, evento: 'streaming', diam_mm: DIAM_MM, t_ms: Math.round(T * 1000) + 200, carga_kN: kN, tensao_MPa: mpa(kN) });
  }
  rodando = false;
}

// Reproduz um log capturado pelo serial-discovery e re-emite como leituras.
// Espera linhas "t_ms,carga_kN" ou JSON por linha.
async function replay(file) {
  const linhas = readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
  pub({ device: DEVICE, evento: 'inicio', diam_mm: DIAM_MM, t_ms: 0, carga_kN: 0, tensao_MPa: 0 });
  let pico = 0;
  for (const ln of linhas) {
    let t_ms, kN;
    if (ln.trim().startsWith('{')) { const o = JSON.parse(ln); t_ms = o.t_ms; kN = o.carga_kN; }
    else { const [a, b] = ln.split(','); t_ms = Number(a); kN = Number(b); }
    if (Number.isNaN(kN)) continue;
    pico = Math.max(pico, kN);
    pub({ device: DEVICE, evento: 'streaming', diam_mm: DIAM_MM, t_ms, carga_kN: kN, tensao_MPa: mpa(kN) });
    await sleep(120);
  }
  pub({ device: DEVICE, evento: 'ruptura', diam_mm: DIAM_MM, t_ms: 0, carga_kN: pico, tensao_MPa: mpa(pico) });
  console.log(`[sim] replay concluido. Pico ${pico} kN`);
}

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) { o[argv[i].slice(2)] = (argv[i + 1] && !argv[i + 1].startsWith('--')) ? argv[++i] : true; }
  }
  return o;
}
