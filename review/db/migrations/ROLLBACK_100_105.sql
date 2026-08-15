-- WARNING: Prefer restoring a SQLite .backup created by Invoke-ReviewMigrations.ps1 -Backup.
-- This SQL rollback is best-effort and DESTRUCTIVE for Review-MVP objects.
-- Do NOT run against a production database.
--
-- Covers Review migrations 100–105.
-- Migration 105 adds indexes only (no new tables); drop those indexes explicitly below.
--
-- Prefer: restore pre-migration .backup over SQL DROP scripts.

-- Uncomment the following line only after intentional review:
-- SELECT CASE WHEN 1 THEN RAISE(ABORT,'Refusing ROLLBACK_100_105.sql without explicit edit') END;

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

-- Indexes added on existing core tables by migrations 101/102
DROP INDEX IF EXISTS ix_discoveries_project_source_media;
DROP INDEX IF EXISTS ix_discoveries_project_origin_cat;
DROP INDEX IF EXISTS ix_discoveries_project_category_source_value;
DROP INDEX IF EXISTS ix_discoveries_project_parent;
DROP INDEX IF EXISTS ix_media_current_uploader;
DROP INDEX IF EXISTS ix_categories_title;
DROP INDEX IF EXISTS ix_categories_normalized_title;
DROP INDEX IF EXISTS ix_project_categories_parent;

-- Indexes added by migration 105 (perf helpers only)
DROP INDEX IF EXISTS ix_discoveries_project_media_source;
DROP INDEX IF EXISTS ix_discoveries_project_series_types;
DROP INDEX IF EXISTS ix_discoveries_project_keyword_query;

DELETE FROM review_schema_migrations WHERE version IN (100,101,102,103,104,105);
DROP TABLE IF EXISTS review_schema_migrations;
-- Never touch core schema_migrations for Review versions.
COMMIT;
