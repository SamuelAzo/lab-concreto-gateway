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
