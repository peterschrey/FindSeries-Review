import Database from 'better-sqlite3';
import path from 'node:path';

export type ReviewDb = Database.Database;

export function openReviewDb(databasePath: string, opts?: { readonly?: boolean }): ReviewDb {
  const resolved = path.resolve(databasePath);
  const db = new Database(resolved, {
    readonly: opts?.readonly ?? false,
    fileMustExist: true,
  });
  db.pragma('busy_timeout = 5000');
  db.pragma('foreign_keys = ON');
  if (opts?.readonly) {
    db.pragma('query_only = ON');
  } else {
    // Short writer transactions; WAL is already used by FindSeries.
    db.pragma('journal_mode = WAL');
  }
  return db;
}

export function utcNow(): string {
  const d = new Date();
  const ms = String(d.getUTCMilliseconds()).padStart(3, '0');
  return d.toISOString().replace(/\.\d{3}Z$/, `.${ms}Z`);
}
