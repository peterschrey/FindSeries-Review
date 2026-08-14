import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openReviewDb, type ReviewDb } from '../src/db.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');

export function createSyntheticReviewDb(): { db: ReviewDb; dbPath: string; cleanup: () => void } {
  const dbPath = path.join(os.tmpdir(), `findseries-review-api-${process.pid}-${Date.now()}.db`);
  const ps1 = path.join(repoRoot, 'review/db/tests/New-Phase1TestDatabase.ps1');
  const migrate = path.join(repoRoot, 'review/db/Invoke-ReviewMigrations.ps1');
  execFileSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1, '-DatabasePath', dbPath],
    { stdio: 'pipe' },
  );
  execFileSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', migrate, '-DatabasePath', dbPath],
    { stdio: 'pipe' },
  );

  const db = openReviewDb(dbPath);
  db.exec(`
    INSERT OR IGNORE INTO categories(id, title, normalized_title, created_at)
    VALUES (200, 'Category:Fallback Only', 'category:fallback only', '2026-08-14T12:00:00.000Z');
    INSERT OR IGNORE INTO project_categories(
      project_id, category_id, parent_category_id, depth, status, member_count, file_count, child_count, discovered_at, updated_at
    ) VALUES (7, 200, 100, 1, 'done', 1, 1, 0, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
    INSERT OR IGNORE INTO media(id, title, current_uploader, created_at, updated_at)
    VALUES (200, 'File:Fallback.jpg', 'UploaderC', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
    INSERT OR IGNORE INTO project_media(project_id, media_id, score, selected, download_requested, first_seen_at, updated_at)
    VALUES (7, 200, 5, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
    INSERT OR IGNORE INTO discoveries(project_id, media_id, source_type, source_value, score, query_text, origin_category_id, parent_media_id, created_at)
    VALUES (7, 200, 'category', 'Category:Fallback Only', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z');
    INSERT OR REPLACE INTO downloads(
      media_id, status, local_path, historical_complete, attempts, created_at, updated_at
    ) VALUES
      (1, 'done', 'C:/Temp/FindSeries-Review-Test/files/present-1.jpg', 1, 0, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
      (2, 'done', 'C:/Temp/FindSeries-Review-Test/files/missing-2.jpg', 1, 0, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
  `);

  const cleanup = () => {
    try {
      db.close();
    } catch {
      /* ignore */
    }
    for (const p of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
      try {
        fs.unlinkSync(p);
      } catch {
        /* ignore */
      }
    }
  };
  return { db, dbPath, cleanup };
}
