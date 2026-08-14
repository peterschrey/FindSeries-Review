# Phase-1 Checkpoint (FRV-1 … FRV-10)

**Stand:** 2026-08-14 (nach Review-Korrekturschleife + Stack-Update)  
**Branch:** `review-mvp`  
**Stop:** Vor FRV-11 / Phase 2 Backend – externer Review erneut vorgesehen.

### Stack-Update vor Phase 2 (verbindlich)

P0-Review-Stack laut aktualisiertem `ARCHITECTURE.md`:

- Frontend: **Vite + React + TypeScript**
- Backend: **Node.js + TypeScript + Fastify**
- SQLite: **better-sqlite3** (bevorzugt)
- Gemeinsame Verträge: **`review/shared/`**
- **Kein Python/FastAPI** im P0-Web/API-Stack; P0 muss ohne Python laufen.
- Python nur optional als späterer P1-ML-Worker.

Fachliche DoDs der FRV-11ff-Tasks bleiben unverändert; nur technische Kontext-/Stack-Hinweise werden angepasst.

## 1. Tasks FRV-1 … FRV-10

| ID | Task | Phase | Status | DoD erfüllt? |
|---|---|---|---|---|
| FRV-1 | MVP-Scope, Ziele und Nicht-Ziele | 0 | Done | Ja – `SCOPE.md` |
| FRV-2 | Review-Status und Schutzregeln | 0 | Done | Ja – `STATUS_RULES.md` |
| FRV-3 | Semantik Herkunft/Discovery/Gruppen | 0 | Done | Ja – `PROVENANCE.md` |
| FRV-4 | Technische MVP-Architektur | 0 | Done | Ja – `ARCHITECTURE.md` |
| FRV-5 | Review-Tabellen und Historie | 1 | Done | Ja – Migration 100 + Merge-Schutz + Schema-Test |
| FRV-6 | Provenienzmodell ableiten | 1 | Done | Ja – Map + ≥50 reale Medien (`Test-ProvenanceSample.ps1`) |
| FRV-7 | Kategoriegraph / Unterbaum | 1 | Done | Ja – Cat_Dentistry real + CTE/Union/FK-Plausibilität |
| FRV-8 | Serienidentität / Reihenfolge | 1 | Done | Ja – ≥10 reale Serien + Natural-Sort-Demo |
| FRV-9 | Similarity-Metadaten (P1) | 1 | Done | Ja – Schema 104 korrigiert; nicht P0-Blocker |
| FRV-10 | Migrationen / Versionierung | 1 | Done | Ja – Real-DB `.backup` + 2× Apply (`REAL_DB_MIGRATION_TEST.md`) |

Details der Korrekturen: `PHASE1_REVIEW_FIXES.md`.

## 2. Geänderte / neue Architektur- und DB-Dateien

### Docs

- `docs/review-mvp/MVP_SPEC.md`
- `docs/review-mvp/SCOPE.md`, `STATUS_RULES.md`, `PROVENANCE.md`, `PROVENANCE_MODEL.md`
- `docs/review-mvp/CATEGORY_GRAPH.md`, `SERIES_MODEL.md`, `SIMILARITY_MODEL.md`
- `docs/review-mvp/SCHEMA_REVIEW.md`, `DATA_MODEL.md`, `ARCHITECTURE.md`, `CURRENT_ARCHITECTURE.md`
- `docs/review-mvp/PHASE1_CHECKPOINT.md`, `PHASE1_REVIEW_FIXES.md`, `REAL_DB_MIGRATION_TEST.md`
- `docs/review-mvp/prototypes/review-mvp.html`
- `.cursor/rules/findseries-review-mvp.mdc`

### DB / Code

- `review/db/migrations/100_review_status.sql` … `104_similarity_meta.sql`
- `review/db/migrations/ROLLBACK_100_104.sql`
- `review/db/Invoke-ReviewMigrations.ps1` (SQLite `.backup main`, quick_check)
- `review/db/fixtures/schema.sql.clean`
- `review/db/tests/*` (inkl. Real-Verify + Merge-Tests)
- `Modules/FindSeries.Database.psm1` (`Get-FsReviewMergeSql` / Review-Merge)

Keine Schreib-/Migrationsänderung an der Produktiv-DB. Keine Phase-2-API.

## 3. Endgültiges Datenmodell (kompakt)

- **Review:** sparse `media_review_status` + History + Batches; fehlende Zeile = `unreviewed`; projektbezogen, global über Filter des Projekts; `media_rejections` bleibt workspaceweit und wird durch normales `reject` **nicht** auto-befüllt.
- **Zeitformat Review:** `YYYY-MM-DDTHH:mm:ss.fffZ` (UTC).
- **Provenienz:** discoveries + type_map; Seed Neighbor=`media:<parent>`, Keyword=normalisierte Query, sonst NULL.
- **Kategorie:** Recursive CTE / Union + DISTINCT; Closure optional leer.
- **Serie:** filename / uploader_time / discovery; `media_series_keys` mit UNIQUE partial primary.
- **Similarity (P1):** Embeddings modellisoliert; pHash mit Algorithmus/Version, pending ohne Hash.

## 4. Migrationen und Indizes

| Ver | Objekte |
|---|---|
| 100 | `media_review_*` |
| 101 | `review_provenance_type_map` + Discovery-/Uploader-Indizes |
| 102 | `ix_project_categories_parent` + leere Closure |
| 103 | `media_series_keys` + `ux_media_series_keys_one_primary` |
| 104 | Embeddings/pHash (nullable Hash, algorithm PK) |

## 5. Verifikation (Kurz)

| Check | Ergebnis |
|---|---|
| Synthetisch Phase1 / Merge / Schema | PASS |
| Real Provenance ≥50 | PASS |
| Real Category Cat_Dentistry | PASS (u. a. 62% category-discoveries ohne `origin_category_id`) |
| Real Series ≥10 | PASS |
| Real-DB Migration 100–104 2× | PASS – siehe `REAL_DB_MIGRATION_TEST.md` |

## 6. Offene Annahmen / Restrisiken

1. Seed Search bleibt abgeleitet (kein natives `source_type`).
2. Hoher Anteil fehlender `origin_category_id` → Backend-Fallback auf `source_value` nötig.
3. Undo späterer Batches muss Current-`batch_id` respektieren (Merge-Schutz).
4. Produktiv-DB unter Dauerlast: Online-Backup bevorzugt über CLI mit `main` bzw. Backup-API.
5. FRV-11 (Galerie-API) **nicht** gestartet.
6. Erste Backend-Implementierung ist Node/Fastify/TS (nicht FastAPI).

## 7. Nächster Schritt

Externer Review des Branches `review-mvp` (inkl. Stack-Update), danach Freigabe für **FRV-11** auf dem Node/Fastify-Stack.
