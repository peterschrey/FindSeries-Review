-- FindSeries Review MVP – migration 100: review status + history
-- Idempotent. Does not alter download/discovery tables.
-- Default for legacy media: no row => unreviewed (sparse model).

PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS media_review_status (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK(status IN ('unreviewed','keep','reject','unsure')),
    changed_at TEXT NOT NULL,
    changed_by TEXT,
    source TEXT NOT NULL DEFAULT 'ui',
    action TEXT,
    batch_id TEXT,
    PRIMARY KEY(project_id, media_id)
);

CREATE INDEX IF NOT EXISTS ix_media_review_status_project_status
    ON media_review_status(project_id, status, media_id);

CREATE INDEX IF NOT EXISTS ix_media_review_status_batch
    ON media_review_status(batch_id)
    WHERE batch_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS media_review_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    old_status TEXT NOT NULL CHECK(old_status IN ('unreviewed','keep','reject','unsure')),
    new_status TEXT NOT NULL CHECK(new_status IN ('unreviewed','keep','reject','unsure')),
    changed_at TEXT NOT NULL,
    changed_by TEXT,
    source TEXT NOT NULL DEFAULT 'ui',
    action TEXT,
    batch_id TEXT,
    session_id TEXT,
    details_json TEXT
);

CREATE INDEX IF NOT EXISTS ix_media_review_history_project_time
    ON media_review_history(project_id, id DESC);

CREATE INDEX IF NOT EXISTS ix_media_review_history_batch
    ON media_review_history(batch_id)
    WHERE batch_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_media_review_history_media
    ON media_review_history(project_id, media_id, id DESC);

CREATE TABLE IF NOT EXISTS media_review_batches (
    batch_id TEXT PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    action TEXT NOT NULL,
    target_status TEXT NOT NULL CHECK(target_status IN ('unreviewed','keep','reject','unsure')),
    protect_keep INTEGER NOT NULL DEFAULT 1,
    media_count INTEGER NOT NULL DEFAULT 0,
    changed_count INTEGER NOT NULL DEFAULT 0,
    protected_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    undone_at TEXT,
    source TEXT NOT NULL DEFAULT 'ui',
    session_id TEXT,
    details_json TEXT
);

CREATE INDEX IF NOT EXISTS ix_media_review_batches_project_time
    ON media_review_batches(project_id, created_at DESC);

INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(100, datetime('now'));

COMMIT;
