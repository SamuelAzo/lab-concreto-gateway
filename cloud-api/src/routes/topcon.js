import { Router } from 'express';
import { cpsPendentes, localizarCp, gravarRuptura } from '../topcon.js';

export const topconRouter = Router();

// GET /api/cps-pendentes?data=YYYY-MM-DD  (default: hoje)
// Lista os CPs a romper na data (read-only, via MCP -> topsys).
topconRouter.get('/cps-pendentes', async (req, res) => {
  const data = req.query.data || new Date().toISOString().slice(0, 10);
  try {
    const cps = await cpsPendentes(data);
    const lista = Array.isArray(cps) ? cps : [];
    res.json({ data, total: lista.length, cps: lista });
  } catch (e) {
    res.status(502).json({ erro: 'Falha ao consultar Topcon (MCP)', detalhe: e.message, data });
  }
});

// GET /api/cp/:cp  -> mostra o estado atual do CP (read-only). Útil pra conferir antes de gravar.
topconRouter.get('/cp/:cp', async (req, res) => {
  try {
    const achados = await localizarCp(req.params.cp);
    res.json({ cp: req.params.cp, total: achados.length, achados });
  } catch (e) {
    res.status(502).json({ erro: 'Falha ao consultar CP (MCP)', detalhe: e.message });
  }
});

// POST /api/ruptura  { cp, kN }  -> grava a carga de ruptura no topsys (via mysql_write).
// Seguro: só grava em CP pendente (carga=0), com a PK completa no WHERE.
topconRouter.post('/ruptura', async (req, res) => {
  const { cp, kN } = req.body || {};
  if (!cp || typeof kN !== 'number') return res.status(400).json({ erro: 'informe cp (string) e kN (number)' });
  try {
    const r = await gravarRuptura(String(cp), kN);
    res.status(r.ok ? 200 : 409).json(r);
  } catch (e) {
    res.status(502).json({ erro: 'Falha ao gravar (MCP)', detalhe: e.message, cp, kN });
  }
});
