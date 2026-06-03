import express from 'express';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { startBridge } from './mqtt-bridge.js';
import { ensaiosRouter } from './routes/ensaios.js';
import { comandosRouter } from './routes/comandos.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;

const app = express();
app.use(express.json());

// SSE: empurra "atualizou" para o dashboard quando chega leitura nova
const sseClients = new Set();
function broadcast() { for (const res of sseClients) res.write(`data: ping\n\n`); }

const bridge = startBridge(broadcast);

app.get('/api/health', (_req, res) => res.json({ ok: true, ts: Date.now() }));
app.get('/api/stream', (req, res) => {
  res.set({ 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
  res.flushHeaders?.();
  res.write('retry: 3000\n\n');
  sseClients.add(res);
  req.on('close', () => sseClients.delete(res));
});

app.use('/api/ensaios', ensaiosRouter);
app.use('/api/dispositivos', comandosRouter(bridge));

app.use(express.static(join(__dirname, '..', 'public')));

app.listen(PORT, () => console.log(`[api] http://localhost:${PORT}`));
