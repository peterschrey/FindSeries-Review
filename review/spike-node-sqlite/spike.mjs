// Mini-spike: Node + Fastify + better-sqlite3 (P0 stack check)
// Usage (from repo root):
//   cd review/spike-node-sqlite
//   npm install
//   npm run spike -- --db "C:/Temp/FindSeries-Review-Test/findseries-v5-phase1-gate.db"

import Database from 'better-sqlite3';
import Fastify from 'fastify';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    db: { type: 'string' },
    projectId: { type: 'string', default: '7' },
  },
});

const dbPath = values.db;
if (!dbPath) {
  console.error('Missing --db path to a FindSeries SQLite copy (never production).');
  process.exit(2);
}

const projectId = Number(values.projectId ?? '7');
const db = new Database(dbPath, { readonly: true, fileMustExist: true });
db.pragma('busy_timeout = 5000');
db.pragma('query_only = ON');

const project = db.prepare('SELECT id, name, slug FROM projects WHERE id = ?').get(projectId);
const mediaCount = db.prepare('SELECT COUNT(*) AS c FROM media').get();
const pmCount = db
  .prepare('SELECT COUNT(*) AS c FROM project_media WHERE project_id = ?')
  .get(projectId);

console.log(
  JSON.stringify(
    {
      ok: true,
      driver: 'better-sqlite3',
      readonly: true,
      busy_timeout_ms: 5000,
      project,
      mediaCount: mediaCount.c,
      projectMediaCount: pmCount.c,
    },
    null,
    2,
  ),
);

const app = Fastify({ logger: false });
app.get('/health', async () => ({ status: 'ok', stack: 'fastify+better-sqlite3' }));
await app.listen({ host: '127.0.0.1', port: 0 });
const addr = app.server.address();
const port = typeof addr === 'object' && addr ? addr.port : 0;
const res = await fetch(`http://127.0.0.1:${port}/health`);
const body = await res.json();
await app.close();
db.close();

console.log(JSON.stringify({ fastifyHealth: body, closed: true }, null, 2));
