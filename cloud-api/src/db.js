import Database from 'better-sqlite3';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DB_PATH = process.env.DB_PATH || join(__dirname, '..', 'data.sqlite');

export const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');

db.exec(`
CREATE TABLE IF NOT EXISTS ensaios (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  device       TEXT    NOT NULL,
  diam_mm      REAL    DEFAULT 100,
  status          TEXT DEFAULT 'aberto',   -- aberto | finalizado
  pico_kN         REAL,
  tensao_MPa      REAL,
  corpo_de_prova  TEXT,                     -- codigo de barras do CP (Bluetooth)
  started_at      TEXT DEFAULT (datetime('now')),
  finished_at     TEXT
);
CREATE TABLE IF NOT EXISTS leituras (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ensaio_id  INTEGER NOT NULL REFERENCES ensaios(id),
  t_ms       INTEGER,
  carga_kN   REAL,
  tensao_MPa REAL,
  evento     TEXT,
  ts         TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_leituras_ensaio ON leituras(ensaio_id);
`);

// migracao idempotente: adiciona corpo_de_prova em bancos antigos
try { db.exec(`ALTER TABLE ensaios ADD COLUMN corpo_de_prova TEXT`); } catch { /* ja existe */ }

const stmt = {
  novoEnsaio: db.prepare(`INSERT INTO ensaios (device, diam_mm, corpo_de_prova) VALUES (?, ?, ?)`),
  addLeitura: db.prepare(`INSERT INTO leituras (ensaio_id, t_ms, carga_kN, tensao_MPa, evento) VALUES (?,?,?,?,?)`),
  finalizar: db.prepare(`UPDATE ensaios SET status='finalizado', pico_kN=?, tensao_MPa=?, corpo_de_prova=COALESCE(?, corpo_de_prova), finished_at=datetime('now') WHERE id=?`),
  getEnsaio: db.prepare(`SELECT * FROM ensaios WHERE id=?`),
  listEnsaios: db.prepare(`SELECT * FROM ensaios ORDER BY id DESC LIMIT ?`),
  leiturasDe: db.prepare(`SELECT t_ms, carga_kN, tensao_MPa, evento, ts FROM leituras WHERE ensaio_id=? ORDER BY id ASC`),
};

export function novoEnsaio(device, diam_mm = 100, corpo_de_prova = null) {
  return stmt.novoEnsaio.run(device, diam_mm, corpo_de_prova ?? null).lastInsertRowid;
}
export function addLeitura(ensaioId, { t_ms, carga_kN, tensao_MPa, evento }) {
  stmt.addLeitura.run(ensaioId, t_ms ?? null, carga_kN ?? null, tensao_MPa ?? null, evento ?? 'streaming');
}
export function finalizarEnsaio(ensaioId, pico_kN, tensao_MPa, corpo_de_prova = null) {
  stmt.finalizar.run(pico_kN, tensao_MPa, corpo_de_prova ?? null, ensaioId);
}
export function getEnsaio(id) {
  const e = stmt.getEnsaio.get(id);
  if (!e) return null;
  e.leituras = stmt.leiturasDe.all(id);
  return e;
}
export function listEnsaios(limit = 50) {
  return stmt.listEnsaios.all(limit);
}
