import { Router } from 'express';
import { cpsPendentes } from '../topcon.js';

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
