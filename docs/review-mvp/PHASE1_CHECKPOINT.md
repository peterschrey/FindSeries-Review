# Phase-1 Checkpoint (FRV-1 … FRV-10)

**Stand:** 2026-08-14  
**Branch:** `review-mvp`  
**Stop:** Vor FRV-11 / Phase 2 Backend – Freigabe ausstehend.

## 1. Tasks FRV-1 … FRV-10

| ID | Task | Phase | Status | DoD erfüllt? |
|---|---|---|---|---|
| FRV-1 | MVP-Scope, Ziele und Nicht-Ziele | 0 | Done | Ja – `SCOPE.md` an `MVP_SPEC.md` |
| FRV-2 | Review-Status und Schutzregeln | 0 | Done | Ja – `STATUS_RULES.md` |
| FRV-3 | Semantik Herkunft/Discovery/Gruppen | 0 | Done | Ja – `PROVENANCE.md` |
| FRV-4 | Technische MVP-Architektur | 0 | Done | Ja – `ARCHITECTURE.md` |
| FRV-5 | Review-Tabellen und Historie | 1 | Done | Ja – Migration 100 + Test |
| FRV-6 | Provenienzmodell ableiten | 1 | Done | Ja – Map + Indizes + ≥50 Stichprobe |
| FRV-7 | Kategoriegraph / Unterbaum | 1 | Done | Ja – Query-Spec + Parent-Index + Test |
| FRV-8 | Serienidentität / Reihenfolge | 1 | Done | Ja – 3 Strategien + natürliche Sortierung |
| FRV-9 | Similarity-Metadaten (P1) | 1 | Done | Ja – Schema ohne P0-Blockade |
| FRV-10 | Migrationen / Versionierung | 1 | Done | Ja – Runner, Backup, 2× Apply, Rollback-Doku |

## 2. Geänderte / neue Architektur- und DB-Dateien

### Docs

- `docs/review-mvp/MVP_SPEC.md` (verbindliche Spec, vorhanden)
- `docs/review-mvp/SCOPE.md`
- `docs/review-mvp/STATUS_RULES.md`
- `docs/review-mvp/PROVENANCE.md`
- `docs/review-mvp/PROVENANCE_MODEL.md`
- `docs/review-mvp/CATEGORY_GRAPH.md`
- `docs/review-mvp/SERIES_MODEL.md`
- `docs/review-mvp/SIMILARITY_MODEL.md`
- `docs/review-mvp/SCHEMA_REVIEW.md`
- `docs/review-mvp/ARCHITECTURE.md`
- `docs/review-mvp/CURRENT_ARCHITECTURE.md`
- `docs/review-mvp/DATA_MODEL.md`
- `docs/review-mvp/PHASE1_CHECKPOINT.md` (diese Datei)
- `docs/review-mvp/prototypes/review-mvp.html`
- `.cursor/rules/findseries-review-mvp.mdc`

### DB / Migrationen

- `review/db/migrations/100_review_status.sql`
- `review/db/migrations/101_provenance_map.sql`
- `review/db/migrations/102_category_graph.sql`
- `review/db/migrations/103_series_keys.sql`
- `review/db/migrations/104_similarity_meta.sql`
- `review/db/migrations/ROLLBACK_100_104.sql`
- `review/db/Invoke-ReviewMigrations.ps1`
- `review/db/tests/Test-ReviewSchemaMigration.ps1`
- `review/db/tests/New-Phase1TestDatabase.ps1`
- `review/db/tests/Test-Phase1ReviewModel.ps1`

Keine Änderung an produktiver DB. Keine Phase-2-API/UI-Implementierung.

## 3. Endgültiges Datenmodell (kompakt)

Siehe auch `DATA_MODEL.md`.

- **Review:** sparse `media_review_status` + `media_review_history` + `media_review_batches`; Default = kein Row → `unreviewed`; `keep` bei Bulk-Reject geschützt.
- **Provenienz:** `discoveries` + `review_provenance_type_map`; Uploader aus `media`; Seed nur abgeleitet.
- **Kategorie:** `project_categories` Baum + Recursive CTE / Union + DISTINCT; optional Closure.
- **Serie:** Strategien filename / uploader_time / discovery; optional `media_series_keys`.
- **Similarity (P1):** `media_embedding_models` / `media_embeddings` / `media_phash` mit `model_id`-Isolation.

## 4. Migrationen und Indizes

| Ver | Objekte / Indizes |
|---|---|
| 100 | Tabellen `media_review_*`; `ix_media_review_status_project_status`, `_batch`; history/batch Indizes |
| 101 | `review_provenance_type_map`; `ix_discoveries_project_source_media`, `_origin_cat`, `_parent`; `ix_media_current_uploader` |
| 102 | `ix_project_categories_parent`; Tabelle `project_category_closure` + Index |
| 103 | `media_series_keys` + Gruppen-/Primary-Indizes |
| 104 | Embedding-/pHash-Tabellen + Status-/Hash-Indizes |

## 5. Offene Annahmen, Risiken, Datenlücken

1. **Seed Search:** kein natives `source_type`; Ableitung aus `query_text`/`parent_media_id`.
2. **origin_category_id:** auf Produktiv teils langsam zu prüfen / ggf. Lücken – Fallback `source_value` nötig (Backend).
3. **Cat_Dentistry** oft nur `category`-Discoveries – Keyword/Neighbor-Facetten dort leer (erwartbar).
4. **Closure-Tabelle** bewusst unbefüllt – Rebuild erst nach Performance-Messung.
5. **series_keys** bewusst unbefüllt – On-the-fly vs. Batch-Build in Phase 2 entscheiden.
6. **Status-Scope:** projektbezogen (`project_id`,`media_id`); workspaceglobale `media_rejections` bleiben Explorer-Pfad.
7. **Produktiv-DB** unter Last/WAL: schwere Ad-hoc-Queries timeouten – Tests daher auf synthetischer Kopie.
8. **Stack-Festlegung** FastAPI+Vite in ARCHITECTURE – noch nicht implementiert (Phase 2).

## 6. Tests und Ergebnisse

| Test | Ergebnis |
|---|---|
| Read-only Spike Projekte/Counts (Produktiv) | PASS (früher) |
| `Test-ReviewSchemaMigration.ps1` (FRV-5) | PASS |
| `Test-Phase1ReviewModel.ps1` (FRV-6…10): Migration 2×, Backup, Counts, Provenienz ≥50, Subtree/Union, Natural sort 1,2,10, Embedding-Modellisolation, integrity_check | **PASS** (mapped media 55; subtree 6; order 1,2,3; integrity ok) |
| Destruktive Produktiv-Migration | **nicht** ausgeführt (korrekt) |

## 7. Phase 2

**Nicht begonnen.** Nächster Task nach Freigabe: **FRV-11** Galerie-Query API.
