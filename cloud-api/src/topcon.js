// Cliente MCP do servidor Topcon (Railway). A cloud-api consulta o topsys
// (con_cert_resist / con_cert_resist_rup) chamando a tool `mysql_query` por MCP.
// SOMENTE LEITURA nesta etapa. A URL (com token) vem de process.env.TOPCON_MCP_URL.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

let _client = null;

async function getClient() {
  if (_client) return _client;
  const url = process.env.TOPCON_MCP_URL;
  if (!url) throw new Error('TOPCON_MCP_URL não configurado (cloud-api/.env)');
  const transport = new StreamableHTTPClientTransport(new URL(url));
  const c = new Client({ name: 'lab-concreto-cloud-api', version: '0.1.0' });
  await c.connect(transport);
  _client = c;
  return c;
}

// Executa um SELECT via a tool mysql_query do servidor Topcon.
export async function mysqlQuery(sql, params = []) {
  const c = await getClient();
  const res = await c.callTool({ name: 'mysql_query', arguments: { sql, params } });
  const text = (res.content || []).filter((x) => x.type === 'text').map((x) => x.text).join('');
  try { return JSON.parse(text); } catch { return text; }
}

// Executa uma ESCRITA (UPDATE) via a tool mysql_write do servidor Topcon.
// REQUISITO: a tool `mysql_write` precisa estar HABILITADA no servidor MCP.
export async function mysqlWrite(sql, params = []) {
  const c = await getClient();
  const res = await c.callTool({ name: 'mysql_write', arguments: { sql, params } });
  const text = (res.content || []).filter((x) => x.type === 'text').map((x) => x.text).join('');
  try { return JSON.parse(text); } catch { return text; }
}

// Localiza um CP no par (cp1/cp2) e diz em qual slot está + a carga atual + a PK da linha.
export async function localizarCp(cp) {
  const rows = await mysqlQuery(
    `SELECT no_certificado, ano_certificado, usina, serie, nota_fiscal, tp_doc, ruptura,
            cp1_no, cp1_carga, cp2_no, cp2_carga, diamento
       FROM topsys.con_cert_resist_rup
      WHERE cp1_no = ? OR cp2_no = ?
      LIMIT 5`, [cp, cp]);
  if (!Array.isArray(rows) || rows.length === 0) return [];
  return rows.map((r) => {
    const slot = String(r.cp1_no) === String(cp) ? 'cp1' : 'cp2';
    return { ...r, slot, cargaAtual: slot === 'cp1' ? r.cp1_carga : r.cp2_carga };
  });
}

// Grava a ruptura de UM CP: cpN_carga = round(kN*10) (kN×10) e dt_ruptura = hoje.
// Seguro: usa a PK completa no WHERE e só grava se a carga estiver 0 (CP pendente).
export async function gravarRuptura(cp, kN) {
  const cargaInt = Math.round(Number(kN) * 10);
  if (!Number.isFinite(cargaInt) || cargaInt <= 0) return { ok: false, motivo: 'kN inválido', cp, kN };
  const achados = await localizarCp(cp);
  if (achados.length === 0) return { ok: false, motivo: 'CP não encontrado no topsys', cp };
  // o nº do CP NÃO é único: pode aparecer em várias linhas. Só interessa o slot PENDENTE (carga=0).
  const pendentes = achados.filter((a) => Number(a.cargaAtual) === 0);
  if (pendentes.length === 0) return { ok: false, motivo: 'Nenhum slot pendente p/ esse CP (já lançado?)', cp, achados };
  if (pendentes.length > 1) return { ok: false, motivo: 'CP pendente ambíguo (mais de uma linha pendente)', cp, pendentes };
  const a = pendentes[0];

  const col = a.slot === 'cp1' ? 'cp1_carga' : 'cp2_carga';
  const noCol = a.slot === 'cp1' ? 'cp1_no' : 'cp2_no';
  const sql =
    `UPDATE topsys.con_cert_resist_rup
        SET ${col} = ?, dt_ruptura = CURDATE()
      WHERE no_certificado=? AND ano_certificado=? AND usina=? AND serie=?
        AND nota_fiscal=? AND tp_doc=? AND ruptura=? AND ${noCol}=? AND ${col}=0`;
  const params = [cargaInt, a.no_certificado, a.ano_certificado, a.usina, a.serie,
    a.nota_fiscal, a.tp_doc, a.ruptura, cp];
  const res = await mysqlWrite(sql, params);
  return { ok: true, cp, slot: a.slot, kN: Number(kN), cargaGravada: cargaInt, res };
}

// CPs pendentes de ruptura (cp1 e cp2 do par) com data prevista <= dataLimite.
const SQL_PENDENTES = `
SELECT cp, fck, diametro, peca, cli, idade, prevista FROM (
  SELECT r.cp1_no AS cp, c.fck, r.diamento AS diametro, c.peca, c.cli, r.ruptura AS idade,
         DATE(c.dt_moldagem + INTERVAL r.ruptura DAY) AS prevista
  FROM topsys.con_cert_resist_rup r
  JOIN topsys.con_cert_resist c USING
       (no_certificado,ano_certificado,usina,serie,nota_fiscal,tp_doc)
  WHERE r.cp1_carga = 0 AND r.cp1_no <> ''
  UNION ALL
  SELECT r.cp2_no, c.fck, r.diamento, c.peca, c.cli, r.ruptura,
         DATE(c.dt_moldagem + INTERVAL r.ruptura DAY)
  FROM topsys.con_cert_resist_rup r
  JOIN topsys.con_cert_resist c USING
       (no_certificado,ano_certificado,usina,serie,nota_fiscal,tp_doc)
  WHERE r.cp2_carga = 0 AND r.cp2_no <> ''
) t
WHERE prevista = ?
ORDER BY cp
LIMIT 300`;

// CPs cuja data prevista de ruptura é exatamente `data` (default: hoje).
export async function cpsPendentes(data) {
  return mysqlQuery(SQL_PENDENTES, [data]);
}
