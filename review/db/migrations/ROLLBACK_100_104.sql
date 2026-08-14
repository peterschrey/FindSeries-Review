-- Migration rollback notes (manual). Prefer restoring the .bak from Invoke-ReviewMigrations -Backup.
-- Destructive example for empty review structures only:

BEGIN IMMEDIATE;
DROP TABLE IF EXISTS media_phash;
DROP TABLE IF EXISTS media_embeddings;
DROP TABLE IF EXISTS media_embedding_models;
DROP TABLE IF EXISTS media_series_keys;
DROP TABLE IF EXISTS project_category_closure;
DROP TABLE IF EXISTS review_provenance_type_map;
DROP TABLE IF EXISTS media_review_history;
DROP TABLE IF EXISTS media_review_batches;
DROP TABLE IF EXISTS media_review_status;
DELETE FROM schema_migrations WHERE version IN (100,101,102,103,104);
COMMIT;
