-- Migration 105: targeted Review query indexes (FRV-39)
-- Idempotent. No schema table changes. No materialization.
-- Verified against EXPLAIN QUERY PLAN on gate DB; only covering/join helpers
-- that are not already provided by migrations 100–104.

PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

-- Covering index for JOIN discoveries ON (project_id, media_id) + source_type filter
-- (ux_discovery_identity / ix_discoveries_project_media lack source_type as payload).
CREATE INDEX IF NOT EXISTS ix_discoveries_project_media_source
    ON discoveries(project_id, media_id, source_type);

-- Series discovery fallback path in groups/series (source_type IN filename/time-series/…).
CREATE INDEX IF NOT EXISTS ix_discoveries_project_series_types
    ON discoveries(project_id, source_type, media_id, source_value, query_text)
    WHERE source_type IN ('filename-series', 'time-series', 'filename');

-- Seed/keyword path: neighbor parent already indexed; keyword query_text lookups.
CREATE INDEX IF NOT EXISTS ix_discoveries_project_keyword_query
    ON discoveries(project_id, source_type, query_text, media_id)
    WHERE query_text IS NOT NULL AND trim(query_text) <> '';

INSERT OR IGNORE INTO review_schema_migrations(version, applied_at) VALUES(105, datetime('now'));

COMMIT;
