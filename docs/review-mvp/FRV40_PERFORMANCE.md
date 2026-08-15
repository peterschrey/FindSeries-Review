# FRV-40 — Performance Gate (100k+)

**Status:** Testing (Done = nein)  
**Date:** 2026-08-15  
**Branch:** `review-mvp`  
**Review-base:** `d5013ba8c4984ec8f9d547efc8fd47c763d8f3de`  
**Scope:** Technischer Performance-Gate (kein manueller UI-/UX-Test; FRV-47).

## Commands

```bash
npm run test:perf:frv40
npm run bench:frv40:groups-isolate
```

Normale `test:gate` / `test:e2e` bleiben CI-fähig. Perf nicht in GitHub CI erzwingen.

## Hardware / Pfade

| Rolle | Pfad |
|---|---|
| Produktiv (nie) | `C:\FindSeriesV5-Workspace\findseries-v5.db` |
| Read / Gate | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` |
| Write / Bulk | `C:\Temp\FindSeries-Review-Test\bench-write-copy.db` |

- Write nur unter `C:\Temp\FindSeries-Review-Test\` via `assertSafeBenchWriteDb` (vor unlink/rebuild).
- Medienzahl Project 7: **184 991**
- Baseline CSV: **unverändert** (`frv40-results.baseline.csv`)

## Methodik (zwei Ebenen)

1. **Baseline-compatible (Primary):** ein Prozess / eine Connection, Cold-Suite → Warm-Suite — Regression-Gate gegen Baseline-CSV  
2. **Supplemental:** optional `REVIEW_FRV40_SUPPLEMENTAL_CHILD=1` (fresh-process) — nicht 1:1 gegen Baseline flaggen  
3. **Groups-Isolate:** `bench:frv40:groups-isolate` Method A vs B

## A. groups_provenance — Isolation & Fix

### Vor Fix (committed multi-scan path)

| Method | Warm p50 | vs Baseline 1490 ms |
|---|---:|---:|
| A same-process | ~4032 ms | **+170 %** |
| B child (frühere Runs) | ~2.5–3.2 s | **>+70 %** |

**Klassifikation: VERIFIED_REAL** — beide Methodiken >20 % langsamer.

### Ursache (VERIFIED)

Teilmessungen: Key ≈1.2 s + UI-Stats ≈1.2 s + Progress-Stats ≈1.4 s → volles `queryGroups` ≈4.1–4.5 s.  
P0: bei UI ⊂ 4 Statusen liefen mehrere schwere Discoveries-Scans.

### Fix

Ein Aggregat-Pass (`groups.ts`): Scan über alle 4 Status bei Progress-Bedarf; `visible_total` aus UI-Spalten; `progressStatusCounts` aus denselben Daten.

### Nach Fix (Isolate)

| Method | Warm p50 | Δ vs Baseline |
|---|---:|---:|
| A | ~1045–1400 ms | **≤0 / leicht schneller** |
| B | ~963–1172 ms | schneller |

**Klassifikation: VERIFIED_FIXED** — Groups-Flag geschlossen. Primary-Suite: `groups_provenance` **nicht** mehr in Regression-Flags.

## B. Weitere API-Metriken (Primary Warm Run 2)

| Metric | Baseline p50 | Current p50 | Flag |
|---|---:|---:|---|
| gallery | 570.9 | 930.6 | >20 % |
| groups_provenance | 1490.4 | 1431.0 | ok |
| category_subtree | 351.5 | 540.8 | >20 % |
| category_gallery | 1478.2 | 2416.9 | >20 % |
| focus | 1309.4 | 2538.1 | >20 % |
| facets | 1553.6 | 2684.1 | >20 % |
| status_counts | 5.0 | 6.4 | >20 % |

### Einordnung

| Aussage | Label |
|---|---|
| `gallery.ts` / Default-Filter-Pfad seit Baseline-Commit unverändert (`git diff c54ae4b..HEAD`) | VERIFIED |
| Allein-Messungen gallery/focus/facets ebenfalls deutlich über Baseline | VERIFIED |
| Konkrete Code-Ursache für die absolute Elevation | **UNRESOLVED** |
| Host/Runtime-Faktor als Erklärung | INFERRED (nicht belegt) |

Weil **UNRESOLVED >20 %** außerhalb Groups verbleibt → FRV-40 bleibt **Testing / Done = nein** (kein „Methodik/Rauschen“-Abwinken).

Keine spekulative Optimierung dieser Pfade in diesem Fixloop.

## C. Write-DB Safety

- `assertSafeBenchWriteDb()` vor unlink/rebuild  
- Tests: PASS Temp-Write; FAIL Produktiv / Users / E: / andere C: / Gate-DB  
- Bulk: `source: 'frv40-bench'`; restoreOk=true (1 / 100 / 10 000)

## D. Browser (sachlich, keine UI-Optimierung)

| Metric | Cold | Warm |
|---|---:|---:|
| time_to_first_grid_ms | 8745 | 12871 |
| Visible thumbs | 54 | 54 |
| DOM nodes after scroll | — | 8802 |
| Long tasks | 1 | 1 |
| rAF p95 (ms) | — | 16.7 |

First Grid **~8–13 s** — dokumentiert, nicht als „schnell“ gewertet. UX → FRV-47.

## Verdict

| | |
|---|---|
| Groups P0 | **behoben** (VERIFIED_FIXED) |
| Write-DB Guard | **PASS** |
| Bulk restore | **PASS** |
| Baseline CSV | **unverändert** |
| Sonstige >20 % API | **UNRESOLVED** → Testing |
| **Done** | **nein** |

## Artefakte

- `docs/review-mvp/bench/frv40-results.csv` / `.baseline.csv` (immutable)
- `docs/review-mvp/bench/frv40-groups-isolate.csv` / `FRV40_GROUPS_ISOLATE.md`
- `docs/review-mvp/bench/frv40-browser.csv` / `FRV40_BROWSER.md`
- Scripts: `bench-frv40.ts`, `bench-frv40-groups-isolate.ts`, `ensure-frv40-write-db.ts`, `bench-shared.ts`
- Fix: `review/api/src/services/groups.ts`
