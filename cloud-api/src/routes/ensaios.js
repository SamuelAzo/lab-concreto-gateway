import { Router } from 'express';
import { novoEnsaio, addLeitura, finalizarEnsaio, getEnsaio, listEnsaios } from '../db.js';

export const ensaiosRouter = Router();

// Lista os ensaios (mais recentes primeiro)
ensaiosRouter.get('/', (req, res) => {
  res.json(listEnsaios(Number(req.query.limit) || 50));
});

// Detalhe de um ensaio + suas leituras (curva carga x tempo)
ensaiosRouter.get('/:id', (req, res) => {
  const e = getEnsaio(Number(req.params.id));
  if (!e) return res.status(404).json({ erro: 'ensaio nao encontrado' });
  res.json(e);
});

// Abre um ensaio manualmente (alem do fluxo automatico via MQTT)
ensaiosRouter.post('/', (req, res) => {
  const { device = 'manual', diam_mm = 100 } = req.body || {};
  const id = novoEnsaio(device, diam_mm);
  res.status(201).json({ id });
});

// Adiciona uma leitura (streaming ou valor final) a um ensaio existente
ensaiosRouter.post('/:id/leituras', (req, res) => {
  const id = Number(req.params.id);
  const { t_ms, carga_kN, tensao_MPa, evento } = req.body || {};
  addLeitura(id, { t_ms, carga_kN, tensao_MPa, evento });
  if (evento === 'ruptura') finalizarEnsaio(id, carga_kN, tensao_MPa);
  res.status(201).json({ ok: true });
});
