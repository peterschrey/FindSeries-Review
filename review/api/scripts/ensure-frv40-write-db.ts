/**
 * Ensure C:\Temp\...\bench-write-copy.db exists with ≥100k project_media (project 7).
 * Compact metadata extract from the C: gate DB — not a full 20GB clone.
 *
 *   npx tsx scripts/ensure-frv40-write-db.ts [--force]
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Database from 'better-sqlite3';
import {
  DEFAULT_PERF_DB,
  DEFAULT_WRITE_DB,
  assertSafeBenchDb,
  repoRoot,
} from './bench-shared.js';

const PROJECT_ID = 7;
const MIN_MEDIA = 100_000;

function countPm(dbPath: string): number {
  const db = new Database(dbPath, { readonly: true, fileMustExist: true });
  try {
    return (
      db.prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id=?`).get(PROJECT_ID) as {
        c: number;
      }
    ).c;
  } finally {
    db.close();
  }
}

function createTableFromGate(w: Database.Database, table: string): void {
  const row = w.prepare(`SELECT sql FROM g.sqlite_master WHERE type='table' AND name=?`).get(table) as
    | { sql: string }
    | undefined;
  if (!row?.sql) throw new Error(`Missing gate table DDL for ${table}`);
  w.exec(row.sql);
}

export function ensureFrv40WriteDb(opts?: {
  gatePath?: string;
  writePath?: string;
  force?: boolean;
}): string {
  const write = assertSafeBenchDb(opts?.writePath ?? DEFAULT_WRITE_DB);
  const gate = assertSafeBenchDb(opts?.gatePath ?? DEFAULT_PERF_DB);
  if (!fs.existsSync(gate)) throw new Error(`Gate DB missing: ${gate}`);

  if (!opts?.force && fs.existsSync(write)) {
    try {
      const n = countPm(write);
      if (n >= MIN_MEDIA) {
        // Verify media has PK (required for review FK)
        const db = new Database(write, { readonly: true, fileMustExist: true });
        const pk = db
          .prepare(`SELECT COUNT(*) AS c FROM pragma_table_info('media') WHERE pk>0`)
          .get() as { c: number };
        db.close();
        if (n >= MIN_MEDIA && pk.c > 0) {
          console.log(`Write DB OK: ${write} (project_media=${n})`);
          return write;
        }
        console.warn('Write DB missing media PRIMARY KEY — rebuilding');
      } else {
        console.warn(`Write DB present but only ${n} media — rebuilding`);
      }
    } catch (e) {
      console.warn(`Write DB unreadable — rebuilding (${e})`);
    }
  }

  for (const p of [write, `${write}-wal`, `${write}-shm`, `${write}-journal`]) {
    try {
      if (fs.existsSync(p)) fs.unlinkSync(p);
    } catch {
      /* ignore */
    }
  }

  console.log(`Building compact write DB from gate → ${write}`);
  const w = new Database(write);
  try {
    w.pragma('journal_mode = OFF');
    w.pragma('synchronous = OFF');
    w.pragma('foreign_keys = OFF');
    w.exec(`ATTACH DATABASE '${gate.replace(/'/g, "''")}' AS g`);

    for (const t of [
      'projects',
      'media',
      'project_media',
      'discoveries',
      'categories',
      'project_categories',
      'downloads',
      'schema_migrations',
    ]) {
      createTableFromGate(w, t);
    }

    w.exec(`INSERT INTO projects SELECT * FROM g.projects WHERE id=${PROJECT_ID}`);
    w.exec(`INSERT INTO project_media SELECT * FROM g.project_media WHERE project_id=${PROJECT_ID}`);
    w.exec(`
INSERT INTO media
SELECT m.* FROM g.media m
WHERE m.id IN (SELECT media_id FROM g.project_media WHERE project_id=${PROJECT_ID})
`);
    w.exec(`INSERT INTO schema_migrations SELECT * FROM g.schema_migrations`);
    // Leave discoveries/categories/downloads/project_categories empty (structure only)

    w.exec('DETACH DATABASE g');
    w.pragma('journal_mode = WAL');
    w.pragma('synchronous = NORMAL');
    w.pragma('foreign_keys = ON');
  } finally {
    w.close();
  }

  const migrate = path.join(repoRoot, 'review/db/Invoke-ReviewMigrations.ps1');
  execFileSync(
    'powershell.exe',
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      migrate,
      '-DatabasePath',
      write,
      '-SkipIntegrity',
    ],
    { stdio: 'inherit' },
  );

  const n = countPm(write);
  if (n < MIN_MEDIA) throw new Error(`Write DB build failed: project_media=${n}`);
  const sizeMb = (fs.statSync(write).size / (1024 * 1024)).toFixed(1);
  console.log(`Write DB ready: ${write} (${n} media, ${sizeMb} MB)`);
  return write;
}

const isMain =
  Boolean(process.argv[1]) &&
  path.resolve(fileURLToPath(import.meta.url)) === path.resolve(process.argv[1]!);
if (isMain) {
  ensureFrv40WriteDb({ force: process.argv.includes('--force') });
}
