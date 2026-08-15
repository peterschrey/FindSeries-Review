/**
 * FRV-42: apply migrations 100–105 on a fresh phase-1 fixture and assert
 * review_schema_migrations. Uses the same PowerShell helpers as createSyntheticReviewDb
 * (no production / 19GB DB).
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it, after } from 'node:test';
import { openReviewDb } from '../src/db.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');

describe('FRV-42 migrations 100–105 on fresh phase1 fixture', () => {
  const dbPath = path.join(
    os.tmpdir(),
    `findseries-review-mig-gate-${process.pid}-${Date.now()}.db`,
  );

  after(() => {
    for (const p of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
      try {
        fs.unlinkSync(p);
      } catch {
        /* ignore */
      }
    }
  });

  it('creates fixture, applies 100–105, records all versions (idempotent re-run)', () => {
    const ps1 = path.join(repoRoot, 'review/db/tests/New-Phase1TestDatabase.ps1');
    const migrate = path.join(repoRoot, 'review/db/Invoke-ReviewMigrations.ps1');

    execFileSync(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1, '-DatabasePath', dbPath],
      { stdio: 'pipe' },
    );
    assert.ok(fs.existsSync(dbPath));

    // Fresh fixture must not already have review migrations.
    {
      const db = openReviewDb(dbPath);
      try {
        const hasTable = db
          .prepare(
            `SELECT 1 AS x FROM sqlite_master WHERE type='table' AND name='review_schema_migrations'`,
          )
          .get() as { x: number } | undefined;
        assert.equal(hasTable, undefined);
      } finally {
        db.close();
      }
    }

    execFileSync(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', migrate, '-DatabasePath', dbPath],
      { stdio: 'pipe' },
    );

    // Second apply must stay idempotent.
    execFileSync(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', migrate, '-DatabasePath', dbPath],
      { stdio: 'pipe' },
    );

    const db = openReviewDb(dbPath);
    try {
      const versions = (
        db
          .prepare(
            `SELECT version FROM review_schema_migrations
             WHERE version BETWEEN 100 AND 105
             ORDER BY version`,
          )
          .all() as Array<{ version: number }>
      ).map((r) => Number(r.version));
      assert.deepEqual(versions, [100, 101, 102, 103, 104, 105]);

      const leaked = db
        .prepare(
          `SELECT COUNT(*) AS c FROM schema_migrations WHERE version BETWEEN 100 AND 105`,
        )
        .get() as { c: number };
      assert.equal(Number(leaked.c), 0);

      const qc = db.pragma('quick_check', { simple: true });
      assert.equal(qc, 'ok');
    } finally {
      db.close();
    }
  });
});
