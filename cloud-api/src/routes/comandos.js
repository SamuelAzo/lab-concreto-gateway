import { Router } from 'express';

// Recebe o "bridge" para publicar comandos no MQTT (nuvem -> gateway)
export function comandosRouter(bridge) {
  const r = Router();

  // POST /api/dispositivos/:id/comando  { "cmd": "READ?" | "*IDN?" | "START" | "STOP" }
  r.post('/:id/comando', (req, res) => {
    const device = req.params.id;
    const cmd = (req.body && req.body.cmd) || 'READ?';
    const permitidos = ['READ?', '*IDN?', 'START', 'STOP', 'TARE'];
    if (!permitidos.includes(cmd)) {
      return res.status(400).json({ erro: `cmd invalido. Use um de: ${permitidos.join(', ')}` });
    }
    bridge.enviarComando(device, cmd);
    res.json({ ok: true, device, cmd });
  });

  return r;
}
