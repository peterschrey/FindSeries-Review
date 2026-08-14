-- Migration 101: provenance type map + discovery/uploader indexes for Review MVP
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS review_provenance_type_map (
    source_type TEXT PRIMARY KEY COLLATE NOCASE,
    family TEXT NOT NULL CHECK(family IN ('category','keyword','neighbor','series','uploader','seed','unknown')),
    chip_label TEXT NOT NULL,
    notes TEXT
);

INSERT OR IGNORE INTO review_provenance_type_map(source_type, family, chip_label, notes) VALUES
 ('category','category','Category Search',NULL),
 ('keyword','keyword','Keyword Search',NULL),
 ('keyword-group','keyword','Keyword Search',NULL),
 ('keyword-title','keyword','Keyword Search',NULL),
 ('keyword-group-description','keyword','Keyword Search',NULL),
 ('keyword-group-filename','keyword','Keyword Search',NULL),
 ('depicts-search','keyword','Keyword Search','Wikidata depicts'),
 ('neighbor','neighbor','Neighbor Search',NULL),
 ('time-neighbour','neighbor','Neighbor Search','time window neighbour'),
 ('uploader-neighbour','neighbor','Neighbor Search','same uploader neighbour'),
 ('time-series','series','Serie',NULL),
 ('filename-series','series','Serie',NULL),
 ('filename','series','Serie','filename discovery path');

CREATE INDEX IF NOT EXISTS ix_discoveries_project_source_media
    ON discoveries(project_id, source_type, media_id);

CREATE INDEX IF NOT EXISTS ix_discoveries_project_origin_cat
    ON discoveries(project_id, origin_category_id, media_id)
    WHERE origin_category_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_discoveries_project_parent
    ON discoveries(project_id, parent_media_id, media_id)
    WHERE parent_media_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_media_current_uploader
    ON media(current_uploader COLLATE NOCASE)
    WHERE current_uploader IS NOT NULL AND current_uploader<>'';

INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(101, datetime('now'));
COMMIT;
