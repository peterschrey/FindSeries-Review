-- Migration 104: similarity / embedding / phash metadata (P1, non-blocking for P0)
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS media_embedding_models (
    model_id TEXT PRIMARY KEY,
    dim INTEGER NOT NULL CHECK(dim > 0),
    created_at TEXT NOT NULL,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS media_embeddings (
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    model_id TEXT NOT NULL REFERENCES media_embedding_models(model_id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK(status IN ('pending','ready','error','stale')),
    embedding BLOB,
    embedding_path TEXT,
    error TEXT,
    computed_at TEXT,
    source_sha1 TEXT COLLATE NOCASE,
    PRIMARY KEY(media_id, model_id),
    CHECK(
        (status <> 'ready')
        OR (embedding IS NOT NULL OR (embedding_path IS NOT NULL AND embedding_path <> ''))
    )
);

CREATE INDEX IF NOT EXISTS ix_media_embeddings_status
    ON media_embeddings(model_id, status, media_id);

CREATE TABLE IF NOT EXISTS media_phash (
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    algorithm TEXT NOT NULL DEFAULT 'ahash64-v1',
    phash TEXT,
    status TEXT NOT NULL CHECK(status IN ('pending','ready','error','stale')),
    computed_at TEXT,
    source_sha1 TEXT COLLATE NOCASE,
    PRIMARY KEY(media_id, algorithm),
    CHECK(
        (status <> 'ready')
        OR (phash IS NOT NULL AND phash <> '')
    )
);

CREATE INDEX IF NOT EXISTS ix_media_phash_hash
    ON media_phash(algorithm, phash, media_id)
    WHERE phash IS NOT NULL AND phash <> '';

CREATE INDEX IF NOT EXISTS ix_media_phash_status
    ON media_phash(algorithm, status, media_id);

INSERT OR IGNORE INTO review_schema_migrations(version, applied_at) VALUES(104, datetime('now'));
COMMIT;
