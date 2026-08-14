# Phase-2 Correction Checkpoint (vor FRV-17)

**Stand:** 2026-08-14  
**Branch:** `review-mvp`  
**Basis-Review-HEAD:** `4b68948866225ff1aa62b6207309c8f8b72247df`  
**STOP vor FRV-17**

## 1. Fixes pro Befund

### FRV-16 Finalisierung
- Globale Eligibility: nur wenn **jede** `project_media`-Mitgliedschaft effektiv `reject` ist (fehlende Current-Zeile = unreviewed = blockiert).
- Klassifikation: `eligible_for_global_finalization` | `blocked_by_other_project` | `already_finalized` | `missing_path` | `missing_file` | `path_not_allowed`.
- Finalisierung = kontrollierte Überführung nach `media_rejections` (+ `project_media`/`project_downloads`/`downloads`/`review_exports`), angelehnt an `Reject-FsReviewExport`.
- Preview erzeugt `previewToken` + JSON-Snapshot; Commit **nur** mit diesem Token und **nur** Snapshot-Kandidaten.
- Bereits finalisierte Medien werden beim Preview übersprungen (Vorwärtsfortschritt).
- Physisches Delete nur innerhalb `REVIEW_DELETE_ROOTS` (realpath/Junction-sicher); ohne Roots → kein Unlink.
- Reihenfolge: DB-Rejection zuerst, dann Unlink; Unlink-Fehler belässt Rejection (recoverable Log).

### FRV-15 Undo
- Sparse Undo nur wenn **keine spätere** `media_review_history`-Zeile (`id > history.id`) für dasselbe Medium existiert.
- Beispiel reject→reset A→keep→reset C→Undo A stellt **nicht** reject wieder her.
- Bulk weiterhin eine SQLite-Transaktion (keine Teil-History / kein halber Batch).

### FRV-11 Seek
- `ORDER BY` und Seek nutzen identische `COALESCE(...)`-Normalisierung.
- Cursor validiert sort/dir; malformed/mismatch → **400**.

### Filter
- `statuses` omitted → Default unreviewed+unsure.
- `statuses: []` → leere Ergebnismenge.
- Leere `sourceTypes`/`categoryIds`/`mediaIds` → leer.
- `uploader: null` → NULL/leer; `undefined` → kein Filter.

### FRV-14 Focus/Seed
- Seed exakt nach `PROVENANCE_MODEL.md` (neighbor/parent, keyword/query_text).
- Kein erfundenes `media:<focusMediaId>` außer belegter Neighbor-Parent-Rolle.
- Relationen: `available` + `filter: MediaFilter | null`; Similarity unavailable.

### FRV-12 Uploader
- `(ohne Uploader)` → Drilldown `uploader: null`.
- Facetten: `uploader: null` für leeren Bucket.

### seriesStrategy
- Aus P0-Contract entfernt (FRV-30).

## 2. Neue Tests

`review/api/tests/api.test.ts` — 11 Tests inkl.:
- statuses [] / omitted
- Seek-Matrix alle Sortfelder × asc/desc × 3 Pages
- Cursor 400
- Uploader-null Drilldown + Facetten
- Seed PROVENANCE + unavailable similar
- Undo-Schutz nach späterem Keep/Reset
- Finalize Eligibility / Token / Roots / Idempotenz

## 3. Finalization-Sicherheitsmodell

Siehe Abschnitt FRV-16 oben und `review/api/src/services/finalize.ts`.

## 4. Undo-Nachweis

Test „sparse reset undo does not restore after later keep+reset“: `restoredCount=0`, Current bleibt sparse unreviewed.

## 5. Pagination-Testmatrix

Alle Sortfelder × asc/desc, ≥3 Pages, keine Duplikate, Reihenfolge = Full-Page-Prefix.

## 6. Benchmarks (Gate-DB-Kopie, Projekt 7)

`C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` (~20.3 GB), `npm run bench`:

| Messung | Zeit |
|---|---|
| Gallery page1 / seek | **7.1 / 8.7 ms** |
| Category subtree count | 391 ms |
| Gallery + Category-Filter | 2180 ms |
| Groups provenance | 2314 ms |
| Focus | 2579 ms |
| Bulk 100 / Undo | 12 / 22 ms |
| Bulk 10k / Undo | 529 / 553 ms |

## 7. Verbleibende Risiken

- Category/Group/Focus-Aggregationen 0,4–2 s → FRV-39.
- Similarity P1.
- Finalize ohne `REVIEW_DELETE_ROOTS` finalisiert DB, löscht keine Dateien.
- Preview-Snapshots sind Dateien unter `REVIEW_FINALIZE_LOG_DIR` (kein TTL-GC in P0).

## 8. Branch + SHA

- **Branch:** `review-mvp`
- **Commit:** nach Push
