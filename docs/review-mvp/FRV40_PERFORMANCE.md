# FRV-40 — Performance Gate (100k+)

**Status:** PASS WITH DEVIATION  
**Date:** 2026-08-15 (FIX REVIEW)  
**Branch:** `review-mvp`  
**Review-base:** `d5013ba8c4984ec8f9d547efc8fd47c763d8f3de`  
**Scope:** Technischer Gate only (manuelle UX → FRV-47).

## Commands

```bash
npm run test:perf:frv40
npm run bench:frv40
npm run bench:frv40:browser
npm --prefix review/api run bench:frv40:groups-isolate
```

## Pfade

| Rolle | Pfad |
|---|---|
| Produktiv | nie |
| Read | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` |
| Write | nur unter `C:\Temp\FindSeries-Review-Test\` via `assertSafeBenchWriteDb` → `bench-write-copy.db` |
| Medien | **184 991** |

## Methodik

1. **Primary (Regression-Gate):** ein Prozess / eine Connection, Cold-Suite → Warm-Suite — vergleichbar mit `frv40-results.baseline.csv`
2. **Supplemental:** `REVIEW_FRV40_SUPPLEMENTAL_CHILD=1` (fresh-process) — nicht 1:1 gegen Baseline flaggen
3. Browser: Playwright Real-DB (`frv40-browser.csv`)

Baseline-Datei unverändert.

## A. groups_provenance Isolation — VERIFIED

| | Warm p50 | Δ vs Baseline 1490 ms |
|---|---:|---:|
| Vor Fix, Method A (same-process) | ~3057 ms | **+105 %** |
| Vor Fix, Method B (child) | ~3224 ms | **+116 %** |
| Nach Fix, Method A | ~1398 ms | **−6 %** |
| Nach Fix, Method B | ~1172 ms | **−21 %** |

**Klassifikation vorher:** **A = echte Regression (VERIFIED)** — nicht Methodik/Rauschen.  
Beide Methoden waren >20 % langsamer.

**Ursache (VERIFIED):** Nach P0-Correctness drei Full-Scans (keyOnly + visibleStat + progressStat), je ~1.3–1.5 s.

**Fix:** ein Aggregat-Scan; Visible aus UI-Status-Spalten; `progressStatusCounts` aus derselben Zeile. P0-B-Tests grün.

## B. Weitere >20 %-Flags (methodengleich Warm)

Aktuell (Run 2 Warm, nach Fix): gallery ~1011, category_subtree ~484, category_gallery ~2051, focus ~2040, facets ~3075 vs Baseline ~571 / ~351 / ~1478 / ~1309 / ~1554.

| Flag | Evidence | Einordnung |
|---|---|---|
| groups_provenance | VERIFIED | behoben (s. oben) |
| gallery | **INFERRED** | `gallery.ts` seit Baseline-Commit **unverändert**; Default-Filter-CTE ohne Series-Sonderfall gleich → kein klarer Code-P0; wahrscheinlicher Gate-DB-/Host-Pfad nach FRV-46-Recopy / Messlast |
| focus / facets / category_* | **INFERRED** | Fokus: kleine AND-Semantik seit P0 C; Facets-SQL im Kern unverändert; Absolute weiter Sekunden, kein Minuten-Stall; kein gezielter P0-Fix ohne spekulative Optimierung |

Keine spekulative Optimierung dieser INFERRED-Flags in diesem Fixloop.

## C. Write-DB Guard

`assertSafeBenchWriteDb()`: nur `C:\Temp\FindSeries-Review-Test\…`; FAIL Produktiv / E: / andere C: / Gate als Write-Ziel. Tests in `bench-write-db-guard.test.ts`.

## D. Browser (keine UI-Optimierung)

| | Cold | Warm |
|---|---:|---:|
| time_to_first_grid_ms | ~9299 | ~10235 |
| thumbs DOM | 54 | 54 |
| DOM nodes | — | ~8802 |
| Long tasks | 0 | 0 |
| rAF p95 | — | ~16.7 ms |

First Grid ~9–10 s: gemessen, **nicht** als „schnell“ bewertet (UX → FRV-47). Virtualisierung bounded.

## E. Bulk

1 / 100 / 10k: ~9–27 ms / ~4–9 ms / ~335–432 ms; Undo; **restoreOk=true**.

## Verdict

**PASS WITH DEVIATION**

- Groups-P0: **VERIFIED** behoben  
- Weitere >20 %-Flags: **INFERRED** (kein unveränderter Code-Pfad-P0 für Gallery); kein Minuten-Stall; DoD technisch erfüllt  
- Manuelle UX: FRV-47

## Artefakte

`frv40-results.csv`, `frv40-results.baseline.csv` (immutable), `frv40-groups-isolate.csv`, `FRV40_GROUPS_ISOLATE.md`, `frv40-browser.csv`, `FRV40_BROWSER.md`
