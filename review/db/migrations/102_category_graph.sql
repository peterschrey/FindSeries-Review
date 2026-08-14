-- Migration 102: category parent index + optional closure table (empty, rebuildable)
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

CREATE INDEX IF NOT EXISTS ix_project_categories_parent
    ON project_categories(project_id, parent_category_id, category_id);

-- Rebuildable helper; not populated by this migration (P0 uses recursive CTE).
CREATE TABLE IF NOT EXISTS project_category_closure (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    ancestor_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    descendant_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    depth INTEGER NOT NULL CHECK(depth >= 0),
    PRIMARY KEY(project_id, ancestor_id, descendant_id)
);

CREATE INDEX IF NOT EXISTS ix_project_category_closure_desc
    ON project_category_closure(project_id, descendant_id, ancestor_id);

INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(102, datetime('now'));
COMMIT;
