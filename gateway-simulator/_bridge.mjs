// Bridge PC -> nuvem: le o DIGI-TRON pela USB (via _press_reader.py) e publica
// no mesmo contrato MQTT do gateway. Mostra o dado REAL da prensa no dashboard.
import mqtt from 'mqtt';
import { spawn } from 'node:child_process';

const PORT   = process.env.PORT_SERIAL || '/dev/cu.usbserial-D306E89K';
const PY     = process.env.HOME + '/.local/pipx/venvs/platformio/bin/python';
const PREFIX = 'labconc/topcon-demo';
const DEVICE = 'prensa01';

const AREA_MM2 = Math.PI * 50 * 50;       // Ø100
const KGF_KN   = 0.00980665;              // kgf -> kN
const RUP_MIN  = 5;                        // kN p/ considerar "carregando"
const QUEDA    = 0.80;                      // ruptura: cai abaixo de 80% do pico
const THROTTLE = 150;                       // ms entre publicacoes de streaming
const mpa = kN => +(((kN * 1000) / AREA_MM2)).toFixed(2);

const c = mqtt.connect('wss://broker.hivemq.com:8884/mqtt', { reconnectPeriod: 2000 });
let ready = false;
c.on('connect', () => { ready = true; console.log('[bridge] MQTT conectado -> publicando em', `${PREFIX}/readings/${DEVICE}`); });
c.on('error', e => console.error('[bridge] mqtt erro', e.message));
function pub(o) { if (ready) c.publish(`${PREFIX}/readings/${DEVICE}`, JSON.stringify({ device: DEVICE, diam_mm: 100, ...o })); }

let emEnsaio = false, pico = 0, t0 = 0, lastPub = 0;
function onFrame(txt) {
  const m = txt.match(/(\d{3,})/);          // pega o numero (ignora D/@ e o ponto)
  if (!m) return;
  const kgf = parseInt(m[1], 10);
  const kN  = +(kgf * KGF_KN).toFixed(2);
  const now = Date.now();

  if (!emEnsaio && kN > RUP_MIN) {           // comecou a carregar
    emEnsaio = true; pico = 0; t0 = now;
    pub({ evento: 'inicio', t_ms: 0, carga_kN: 0, tensao_MPa: 0 });
    console.log('[bridge] inicio de ensaio');
  }
  if (emEnsaio) {
    if (kN > pico) pico = kN;
    if (now - lastPub >= THROTTLE) {
      lastPub = now;
      pub({ evento: 'streaming', t_ms: now - t0, carga_kN: kN, tensao_MPa: mpa(kN) });
      process.stdout.write(`\r  carga ${kN.toFixed(1)} kN  | pico ${pico.toFixed(1)} kN = ${mpa(pico)} MPa     `);
    }
    if (pico > RUP_MIN && kN < pico * QUEDA) {  // soltou a carga / rompeu
      pub({ evento: 'ruptura', t_ms: now - t0, carga_kN: pico, tensao_MPa: mpa(pico) });
      console.log(`\n[bridge] RUPTURA: ${pico.toFixed(1)} kN = ${mpa(pico)} MPa`);
      emEnsaio = false; pico = 0;
    }
  }
}

const py = spawn(PY, ['-u', '_press_reader.py', PORT]);
let acc = '';
py.stdout.on('data', d => { acc += d; let i; while ((i = acc.indexOf('\n')) >= 0) { const ln = acc.slice(0, i).trim(); acc = acc.slice(i + 1); if (ln) onFrame(ln); } });
py.stderr.on('data', d => console.error('[py]', d.toString().trim()));
py.on('exit', code => { console.error('[bridge] leitor serial saiu, code', code); process.exit(1); });
console.log('[bridge] lendo', PORT, '-> aplique carga na prensa e veja no celular');
