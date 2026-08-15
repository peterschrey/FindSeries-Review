/**
 * FRV-43: create isolated synthetic SQLite for browser E2E.
 * Phase1 fixture + review migrations 100-105 + deterministic seeds.
 * Never touches production / mini / gate DBs.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');
const sqlite3 = path.join(repoRoot, 'Tools/sqlite3.exe');

export function createFrv43E2eDatabase(targetPath) {
  const dbPath =
    targetPath ??
    path.join(os.tmpdir(), `frv43-e2e-${process.pid}-${Date.now()}.db`);
  for (const p of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
    try {
      fs.unlinkSync(p);
    } catch {
      /* ignore */
    }
  }

  const phase1 = path.join(repoRoot, 'review/db/tests/New-Phase1TestDatabase.ps1');
  const migrate = path.join(repoRoot, 'review/db/Invoke-ReviewMigrations.ps1');
  execFileSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', phase1, '-DatabasePath', dbPath],
    { stdio: 'pipe' },
  );
  execFileSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', migrate, '-DatabasePath', dbPath],
    { stdio: 'pipe' },
  );

  const seedSql = `
INSERT OR REPLACE INTO media_review_status(
  project_id, media_id, status, changed_at, changed_by, source, action, batch_id
) VALUES (
  7, 4, 'keep', '2026-08-15T12:00:00.000Z', 'frv43-fixture', 'seed', 'set_status', NULL
);
INSERT OR REPLACE INTO media_series_keys(
  project_id, media_id, strategy, series_key, sequence_no, sequence_label, is_primary, built_at
) VALUES
  (7, 1, 'filename', 'Dental_chair_series', 1, '01', 1, '2026-08-15T12:00:00.000Z'),
  (7, 2, 'filename', 'Dental_chair_series', 2, '02', 1, '2026-08-15T12:00:00.000Z'),
  (7, 3, 'filename', 'Dental_chair_series', 3, '03', 1, '2026-08-15T12:00:00.000Z'),
  (7, 5, 'filename', 'Instrument_series', 1, '01', 1, '2026-08-15T12:00:00.000Z'),
  (7, 6, 'filename', 'Instrument_series', 2, '02', 1, '2026-08-15T12:00:00.000Z');
INSERT OR IGNORE INTO discoveries(
  project_id, media_id, source_type, source_value, score, query_text, origin_category_id, parent_media_id, created_at
) VALUES
  (7, 2, 'neighbor', 'seed', 30, NULL, NULL, 1, '2026-08-15T12:00:00.000Z'),
  (7, 3, 'neighbor', 'seed', 30, NULL, NULL, 1, '2026-08-15T12:00:00.000Z');
`;
  execFileSync(sqlite3, [dbPath, seedSql], { stdio: 'pipe' });

  const cleanup = () => {
    for (const p of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
      try {
        fs.unlinkSync(p);
      } catch {
        /* ignore */
      }
    }
  };
  return { dbPath, cleanup };
}
