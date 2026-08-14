-- Migration 103: optional materialized series keys (rebuildable)
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS media_series_keys (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    strategy TEXT NOT NULL CHECK(strategy IN ('filename','uploader_time','discovery')),
    series_key TEXT NOT NULL COLLATE NOCASE,
    sequence_no REAL NOT NULL DEFAULT 0,
    sequence_label TEXT,
    is_primary INTEGER NOT NULL DEFAULT 0 CHECK(is_primary IN (0,1)),
    built_at TEXT NOT NULL,
    PRIMARY KEY(project_id, media_id, strategy, series_key)
);

CREATE INDEX IF NOT EXISTS ix_media_series_keys_group
    ON media_series_keys(project_id, strategy, series_key, sequence_no, media_id);

CREATE INDEX IF NOT EXISTS ix_media_series_keys_primary
    ON media_series_keys(project_id, series_key, sequence_no, media_id)
    WHERE is_primary = 1;

INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(103, datetime('now'));
COMMIT;
