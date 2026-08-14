# Phase-2 Backend Checkpoint (FRV-11 … FRV-16)

**Stand:** 2026-08-14  
**Branch:** `review-mvp`  
**Stack (P0):** Node.js + TypeScript + Fastify + better-sqlite3; Contracts in `review/shared/`  
**STOP vor FRV-17 / UI-Grundgerüst**

## 1. Task-Status und DoD

| Task | Status | DoD-Kern |
|---|---|---|
| FRV-11 Galerie-Query | Done | Seek/Cursor-Pagination, stabile Sortierung, unique `media_id`, Meta/Thumb-Key, Total + StatusCounts |
| FRV-12 Gruppen-Aggregation | Done | key/label/total/statusCounts/sample/drilldown für provenance\|category\|series\|uploader |
| FRV-13 Kategorie/Facetten | Done | Lazy Category-Nodes, Subtree-Count (CATEGORY_GRAPH), Provenance-/Uploader-Facetten |
| FRV-14 Fokus-Beziehungen | Done | Ein Request → similar\|series\|category\|seed\|uploader\|provenance (similar = P1-Platzhalter) |
| FRV-15 Bulk + Undo | Done | Batch-ID, Keep-Schutz, History, sparse Reset (DELETE current), Undo nur bei matching `batch_id` |
| FRV-16 Finalisierung | Done | Preview nur `reject`; Commit dry-run/confirm; JSONL-Log; missing/locked Fehlerpfade; keep/unsure nie Kandidaten |

## 2. API-Endpunkte und Verträge

Gemeinsame Types/Schemas: `review/shared/src/contracts.ts`

| Methode | Pfad | Request | Response |
|---|---|---|---|
| GET | `/health` | — | `{ ok: true }` |
| POST | `/api/gallery/query` | `GalleryQuery` | `GalleryResponse` |
| POST | `/api/groups/query` | `GroupQuery` | `GroupsResponse` |
| POST | `/api/categories/nodes` | `CategoryNodeQuery` | `{ nodes: CategoryNode[] }` |
| POST | `/api/facets/query` | `MediaFilter` | `FacetsResponse` |
| POST | `/api/focus/query` | `FocusQuery` | `FocusResponse` |
| POST | `/api/review/bulk` | `BulkRequest` | `BulkResponse` |
| POST | `/api/review/undo` | `UndoRequest` | `UndoResponse` |
| POST | `/api/finalize/preview` | `FinalizePreviewRequest` | `FinalizePreviewResponse` |
| POST | `/api/finalize/commit` | `FinalizeCommitRequest` | `FinalizeCommitResponse` |

`MediaFilter` (geteilt): `projectId`, `statuses` (Default `unreviewed`+`unsure`), `q`, `sourceTypes`, `categoryIds`, `uploader`, `seriesKey`/`seriesStrategy`, `seedKey`, `parentMediaId`, `mediaIds`.

## 3. SQLite-Queries und Indizes

- Filterbasis: `project_media ⋈ media LEFT JOIN media_review_status` + optionale Category-CTE (`origin_category_id` ∪ eindeutiger `source_value`-Fallback laut `CATEGORY_GRAPH.md`).
- Sparse Unreviewed: fehlende Current-Row ⇒ `unreviewed` via `COALESCE(mrs.status,'unreviewed')`.
- **Neue Indizes in Phase 2:** keine. Nutzung der Phase-1-Indizes (Migration 100–104), u. a.:
  - `ix_media_review_status_project_status`, `ix_media_review_status_batch`
  - `ix_media_review_history_*`, `ix_media_review_batches_project_time`
  - `ix_discoveries_project_origin_cat`, `ix_discoveries_project_category_source_value`
  - `ix_categories_normalized_title`, `ix_project_categories_parent`
  - `ix_discoveries_project_source_media`, `ix_discoveries_project_parent`, `ix_media_current_uploader`

## 4. Pagination-Konzept

- Opaque Cursor (`base64url` JSON) mit Sortwert + `media_id` Tie-Breaker.
- Seek-Prädikat (`>` / `<`), **kein OFFSET**.
- `LIMIT n+1` ⇒ `nextCursor`; Seite max. 500.
- Nie Full-Dump der Ergebnismenge.

## 5. Bulk-/Undo-Semantik

- **set_status:** History + UPSERT Current; `protectKeep=true` (Default) überspringt `keep`.
- **reset_unreviewed:** History + **DELETE** Current-Row (sparse).
- Kurze `better-sqlite3`-Transaktion; `batch_id` (UUID) in Status/History/Batches.
- **Undo:** nur wenn `current.batch_id` noch dem Batch entspricht (sonst skip); Restore von `old_status`, bei `unreviewed` wieder DELETE; Batch `undone_at` gesetzt.
- Finalisierung wählt **nur** `status='reject'`; keep/unsure werden nie gelöscht.

## 6. Gemessene Laufzeiten (Real-DB-Kopie)

Quelle: `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` (~20.3 GB), Projekt **7** (`Cat_Dentistry`), `npm run bench` 2026-08-14:

| Messung | Zeit |
|---|---|
| Gallery page1 limit 100 (Default-Filter) | **8.6 ms** |
| Gallery page2 seek | **9.2 ms** |
| Category subtree count (root) | 382.6 ms |
| Gallery + Category-Filter limit 100 | 1953.4 ms |
| Groups provenance limit 20 (sampleSize 0) | 1673.1 ms |
| Focus relations | 1811.3 ms |
| Bulk set_status n=100 | 11.2 ms |
| Undo n=100 | 11.5 ms |
| Bulk set_status n=10 000 | 329.2 ms |
| Undo n=10 000 | 282.1 ms |

Default-Galerie liegt klar unter dem 500‑ms-Ziel. Category-/Group-/Focus-Aggregationen auf dem großen Projekt bleiben Restrisiko / Kandidaten für spätere Materialisierung.

## 7. Tests

- `review/api`: `npm test` — synthetische DB (Phase-1-Fixture + Review-Migrationen 100–104).
- Abdeckung: Pagination ohne Duplikate/Lücken, Category-Fallback, Groups, Facets, Focus, Keep-Schutz, Undo, Finalize-Dry-Run, Fastify-HTTP.

## 8. Restrisiken

- Category-/Group-Counts auf großen Projekten können ohne zusätzliche Materialisierung >500 ms liegen (Warmup-/Filterziel bleibt Monitoring-Thema).
- Provenance-/Series-Group-Joins können Medien in mehreren Gruppen zeigen (gewollt); Totals werden über Drilldown-Filter neu gezählt.
- Similarity (Focus „Ähnlich“) ist bewusst P1-Platzhalter.
- Finalize löscht physisch Dateien nur bei `confirm=true` und `dryRun=false`; Produktiv-DB wird nie angefasst.
- Gate-DB-Kopie kann durch Bench-Writes kurzzeitig dirty sein; Bench macht Undo.

## 9. Branch + Commit

- **Branch:** `review-mvp`
- **Commit:** `4826eab401a897e347923c43584929ad16827215`
