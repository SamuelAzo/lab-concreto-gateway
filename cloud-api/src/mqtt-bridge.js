import mqtt from 'mqtt';
import { novoEnsaio, addLeitura, finalizarEnsaio } from './db.js';

// Broker e prefixo de topicos. Por padrao usa o broker publico (mesmo do dashboard
// GitHub Pages), para o PoC funcionar sem subir Mosquitto. Em producao, aponte
// MQTT_URL para seu broker com TLS/autenticacao.
const MQTT_URL = process.env.MQTT_URL || 'wss://broker.hivemq.com:8884/mqtt';
const PREFIX = process.env.TOPIC_PREFIX || 'labconc/topcon-demo';

// device -> ensaioId em andamento
const emAndamento = new Map();
let onUpdate = () => {};

export function startBridge(notify) {
  if (notify) onUpdate = notify;
  const client = mqtt.connect(MQTT_URL, { clientId: 'cloudapi_' + Math.random().toString(16).slice(2, 8), reconnectPeriod: 2000 });

  client.on('connect', () => {
    console.log(`[mqtt] conectado em ${MQTT_URL} (prefixo ${PREFIX})`);
    client.subscribe(`${PREFIX}/readings/+`);
  });
  client.on('error', (e) => console.error('[mqtt] erro:', e.message));
  client.on('message', (topic, payload) => {
    let r; try { r = JSON.parse(payload.toString()); } catch { return; }
    handleReading(r);
  });

  // exposto para a rota de comando publicar
  return {
    enviarComando(device, cmd) {
      client.publish(`${PREFIX}/commands/${device}`, JSON.stringify({ cmd, ts: Date.now() }));
    },
  };
}

function handleReading(r) {
  const device = r.device || 'desconhecido';

  if (r.evento === 'inicio') {
    const id = novoEnsaio(device, r.diam_mm || 100);
    emAndamento.set(device, id);
    addLeitura(id, r);
    return notify();
  }

  let ensaioId = emAndamento.get(device);
  if (!ensaioId && r.evento !== 'resposta') {
    // leitura sem 'inicio' previo (ex.: stream ja em curso) -> abre ensaio
    ensaioId = novoEnsaio(device, r.diam_mm || 100);
    emAndamento.set(device, ensaioId);
  }
  if (!ensaioId) return; // 'resposta' avulsa a READ? sem ensaio aberto

  addLeitura(ensaioId, r);

  if (r.evento === 'ruptura') {
    finalizarEnsaio(ensaioId, r.carga_kN, r.tensao_MPa);
    emAndamento.delete(device);
  }
  notify();
}

function notify() { try { onUpdate(); } catch {} }
