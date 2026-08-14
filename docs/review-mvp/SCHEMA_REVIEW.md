# Review-Status Schema (FRV-5)

**Bezug:** `STATUS_RULES.md`, `MVP_SPEC.md` §3/16, Migration `review/db/migrations/100_review_status.sql`

## Modell

Sparse, **projektbezogen** (`project_id` + `media_id`):

- Fehlende Zeile in `media_review_status` = **`unreviewed`** (Default für Altbestand, keine Massen-Vorfüllung).
- Normale API-Semantik für Reset/`N`: History schreiben + **Current-Zeile löschen** (sparse bleiben).
- Explizite `status='unreviewed'`-Zeilen sind schema-seitig erlaubt, aber nicht das bevorzugte Runtime-Modell.

Statuswerte: `unreviewed` | `keep` | `reject` | `unsure`.

**Scope:** projektbezogen, aber global über alle Filter/Gruppen dieses Projekts.  
**Nicht** identisch mit workspaceweitem `media_rejections`.

**Identity-Merge:** `Merge-FsMediaRows` remappt History/Status (falls Tabellen existieren) mit Priorität `keep > unsure > reject > unreviewed`.

## Tabellen

### `media_review_status`

Aktueller Status pro Projekt/Medium.

| Spalte | Rolle |
|---|---|
| status | aktueller Status |
| changed_at | letzte Änderung |
| source / action | Herkunft der Änderung (ui, bulk, undo, …) |
| batch_id | letzte Bulk-Aktion (optional) |

Indizes: `(project_id, status, media_id)`, partiell `batch_id`.

### `media_review_history`

Audit je Einzeländerung (auch innerhalb Bulks eine Zeile pro Medium).

| Spalte | Rolle |
|---|---|
| old_status / new_status | Übergang |
| batch_id | Undo-Gruppierung |
| session_id | optionale Session |

### `media_review_batches`

Metadaten einer Bulk-Aktion für Undo/UI-Transparenz (`protect_keep`, Counts).

## Effektiver Status (SQL-Skizze)

```sql
COALESCE(mrs.status, 'unreviewed') AS review_status
-- FROM project_media pm
-- LEFT JOIN media_review_status mrs
--   ON mrs.project_id=pm.project_id AND mrs.media_id=pm.media_id
```

## Nicht Bestandteil

- Keine Änderung an `review_exports` / `media_rejections` / Discovery.
- Kein physisches Löschen.
- Similarity-Tabellen → FRV-9.

## Migration

- Version **100** in `schema_migrations`
- Idempotent (`IF NOT EXISTS` / `INSERT OR IGNORE`)
- Transaktional (`BEGIN IMMEDIATE` … `COMMIT`)
