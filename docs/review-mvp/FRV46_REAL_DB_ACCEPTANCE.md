# FRV-46 — Real-DB Acceptance (Cat_Dentistry)

**Status:** Testing (nicht Done)  
**Verdict:** **PASS WITH DEVIATION**  
**Date:** 2026-08-15

## Evidence classes

| Class | Meaning |
|---|---|
| VERIFIED | gemessen / SQL↔API gegengeprüft in diesem Lauf |
| REPORTED | aus Fixture/DB-Lage dokumentiert, nicht erfunden |
| INFERRED | aus Messdaten abgeleitet |
| NOT_VERIFIED | fehlt / nicht gemessen |

## DB provenance

| Item | Value | Evidence |
|---|---|---|
| Produktiv-DB | `C:\FindSeriesV5-Workspace\findseries-v5.db` | **nie angefasst** |
| Archivquelle | `E:\Temp\FindSeries-Review-Test\archive\findseries-v5-phase1-gate.db` (20 306 485 248 B) | VERIFIED vorhanden, unverändert belassen |
| Arbeit (SSD) | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` | VERIFIED Kopie sequentiell (≈177 s), Größenmatch |
| C: free after copy | ≈26.7 GB | VERIFIED ≥20 GB |
| Project | **7 / Cat_Dentistry** | VERIFIED |
| Medien (`project_media`) | **184 991** | VERIFIED |
| Review migrations | **100–105** (105 nachgezogen auf Kopie) | VERIFIED |
| Core `schema_migrations` | unverändert `1,2,11,12,13,30,32,34,42,44,52,62,65` | VERIFIED |
| `PRAGMA foreign_key_check` | leer/OK | VERIFIED |
| `PRAGMA quick_check` | `ok` | VERIFIED |

Maschinenlesbar: `docs/review-mvp/bench/frv46-acceptance.json`

## Commands

```powershell
# Gate-Kopie muss auf C: liegen (nicht E: querien)
npm run test:frv46
# oder
.\scripts\Invoke-Frv46RealDbAcceptance.ps1 -SkipBrowser
```

API/SQL-Kern: `review/api/scripts/frv46-acceptance.ts`  
Optional Browser: `review/web/acceptance/` + `playwright.frv46.config.ts` (lokal; **nicht** CI)

## Workflow A — Kategorieast

| Field | Value |
|---|---|
| Parent | **14367** `Category:Smiling men in the United States` |
| Real children | 33 (JOIN, nicht stale `child_count`) |
| Descendants | 41 |
| SQL exact membership | 780 |
| SQL subtree membership | 1621 |
| API/UI result (unreviewed+unsure) | 1621 |
| Sample membership | 5/5 OK (CATEGORY_GRAPH) |
| Query | ≈1573 ms gallery / ≈429 ms subtree count |
| Evidence | **VERIFIED** |

## Workflow B — Herkunft / Provenienz

| Field | Value |
|---|---|
| Types in Cat_Dentistry | **nur** `category` (184 991 Medien) |
| Zweiter Typ | **nicht vorhanden** — nicht erfunden | REPORTED |
| GroupCard `category:category` | 184 991 |
| Gallery drilldown | 184 991 MATCH |
| Multi-Provenienz-Stichprobe | 0 (nur ein Typ) |
| Evidence | **VERIFIED** (ein Typ) + **REPORTED** Abweichung |

## Workflow C — Serie

| Field | Value |
|---|---|
| `media_series_keys` | 0 |
| filename-/time-series discoveries | 0 |
| Genutzter Bucket | `(ohne Serie)` total **184 991** |
| Pagination | page1/page2 overlap **0**, monotonic ASC |
| Evidence | **VERIFIED** Fallback; named series **REPORTED** missing |

## Workflow D — Range Review

| Field | Value |
|---|---|
| Range size | **150** (≥100) |
| Keep in range | media **76** (geseedet) |
| changedCount | 149 |
| protectedCount | 1 |
| SQL mismatches | **0** |
| Undo mismatches | **0** |
| Final restore | Ausgang = vorher (sparse) |
| errorRate | **0** |
| Reject / Undo | ≈8 ms / ≈6 ms |
| Stats | before 184 990 → after reject 184 841 → after undo 184 991 (default filter) |
| Evidence | **VERIFIED** |

Kein physisches Delete; Keep-Schutz aktiv (`protectKeep`).

## Workflow E — Fokusbeziehung

| Field | Value |
|---|---|
| Focus media | #1 |
| Used P0 relation | **provenance** (total 1621) |
| Gallery after | 1621 MATCH |
| Similar | disabled / unavailable (P1) |
| Evidence | **VERIFIED** |

## Statistik-Gegenprobe

| Zustand | unreviewed | keep | reject | unsure | total | Evidence |
|---|---:|---:|---:|---:|---:|---|
| Inventory / Ergebnis default | 184991 | 0 | 0 | 0 | 184991 | VERIFIED |
| Nach Keep-Seed + vor Reject | 184990 | (keep aus Filter) | 0 | 0 | 184990 | VERIFIED |
| Nach Range-Reject | 184841 | 0 | 0* | 0 | 184841 | VERIFIED |
| Nach Undo + Keep-Reset | 184991 | 0 | 0 | 0 | 184991 | VERIFIED |

\* Reject-Rows existieren in DB, erscheinen nicht im Default-Resultfilter (unreviewed+unsure). Sparse-unreviewed korrekt gezählt.

## Performance (Cold/Warm, API)

Datei: `docs/review-mvp/bench/frv46-performance.csv`

Methodik: fresh SQLite-Connection cold-ish + warm (wie FRV-40 Klasse; **nicht** OS-disk-cold).

| Metric | FRV-46 Cold p50 (run1) | FRV-40 baseline Cold p50 | Δ |
|---|---:|---:|---|
| gallery | 595 ms | 863 ms | besser |
| groups_provenance | 2754 ms | 1639 ms | **>20 % langsamer** |
| category_subtree | 370 ms | 357 ms | ≈ |
| category_gallery | 1604 ms | 1520 ms | ≈ |
| focus | 1343 ms | 1350 ms | ≈ |
| facets | 1627 ms | 1520 ms | ≈ |
| status_counts | 599 ms | 5 ms | **starke Abweichung** |

**Analyse (INFERRED):** `status_counts` / teilweise Groups liegen deutlich über der FRV-40-Baseline. Mögliche Ursachen: andere Connection-Warmheit, Post-105-Index-Lage, Messpfad über `computeStatusCounts` vs. damaliger Bench. **Kein Schönrechnen** — Deviation dokumentiert. Keine Optimierung in FRV-46.

## Explorer-Baseline

**NOT_VERIFIED / missing**

Keine gemessene Explorer-UI-Baseline in FRV-38/39/40 Docs/CSVs gefunden.

Minimale manuelle Nacharbeit: gleiche Cat_Dentistry-Kategorie/Filter in Explorer vs Review, Stoppuhr für time-to-first-grid + eine Gruppenaktion, Werte in diese Datei nachtragen.

## Browser / Playwright

| Item | Status |
|---|---|
| Stack Browser→Vite→API→Gate-DB | implementiert (`acceptance/`) |
| Node fetch API/Proxy | VERIFIED (gallery total 184991) |
| Chromium UI journeys | **BLOCKED** in Agent-Lauf (Requests hängen / ECONNRESET über Preview-Proxy; Direct-API CORS) |
| Empfehlung | Visuell: `Start-FindSeriesReview.ps1 -DatabasePath C:\Temp\...\findseries-v5-phase1-gate.db -ProductionWeb` |

Orchestrator default: `-SkipBrowser` bis Proxy/Chromium-Pfad stabil. API/SQL deckt die fünf Workflow-Semantiken ab.

## Nutzen / Durchsatz (sachlich)

| Workflow | Medien / Schritt | Reload nötig? | Undo |
|---|---|---|---|
| A Kategorie | 1621 im Subtree | nein | n/a |
| B Provenienz | 184991 | nein | n/a |
| C Serie-Fallback | 184991 + Pagination | nein | n/a |
| D Range | 150 mit Keep-Schutz | nein | ja, restore OK |
| E Fokus | Relation 1621 | nein | Fokus-X |

**Verdict:** PASS WITH DEVIATION — korrekte reversible Review-Semantik und SQL-Matches; Datenlücken (2. Provenienztyp, named Series) und Perf-Abweichungen vs FRV-40 sowie fehlende Explorer-Baseline / Browser-Automation dokumentiert.

## Cleanup

- Review-Status Project 7 nach Acceptance: 0 Rows (VERIFIED)
- E:-Archiv unverändert
- C:-Gate-Kopie **behalten** bis externes Review
- Keine Produktiv-DB-Berührung

## Gate / E2E / CI

Nach Commit: `npm run test:gate`, `npm run test:e2e`, GitHub CI (ohne Real-DB).
