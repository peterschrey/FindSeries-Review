import path from 'node:path';
import { openReviewDb } from './db.js';
import { buildServer } from './server.js';

const databasePath =
  process.env.REVIEW_DB_PATH ??
  path.resolve('C:/Temp/FindSeries-Review-Test/findseries-v5-phase1-gate.db');
const port = Number(process.env.REVIEW_API_PORT ?? 8787);
const host = process.env.REVIEW_API_HOST ?? '127.0.0.1';
const finalizeLogDir =
  process.env.REVIEW_FINALIZE_LOG_DIR ??
  path.resolve('C:/Temp/FindSeries-Review-Test/finalize-logs');
const deleteRoots = (process.env.REVIEW_DELETE_ROOTS ?? '')
  .split(';')
  .map((s) => s.trim())
  .filter(Boolean);

async function main() {
  const readonly = process.env.REVIEW_DB_READONLY === '1';
  const db = openReviewDb(databasePath, { readonly });
  const app = await buildServer({ db, finalizeLogDir, deleteRoots });
  await app.listen({ port, host });
  console.log(
    `review-api listening on http://${host}:${port} db=${databasePath} deleteRoots=${deleteRoots.length}`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
