# FRV-40 — Performance Gate (100k+)

**Status:** PASS  
**Date:** 2026-08-15 (FINAL countercheck)  
**Branch:** `review-mvp`  
**Review-base:** `d5013ba8c4984ec8f9d547efc8fd47c763d8f3de`  
**Scope:** Technischer Gate only (manuelle UX → FRV-47).

## Commands

```bash
npm run test:perf:frv40
npm run bench:frv40
npm run bench:frv40:browser
npm run bench:frv40:ab
npm run bench:frv40:groups-isolate
```

## Pfade

| Rolle | Pfad |
|---|---|
| Produktiv | nie |
| Read | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` |
| Write | `assertSafeBenchWriteDb` → nur `C:\Temp\FindSeries-Review-Test\bench-write-copy.db` |
| Medien | **184 991** |

## Methodik

1. **Primary (Regression-Gate):** same-process Cold→Warm (baseline-compatible suite)
2. **A/B Countercheck:** Review-Base `d5013ba` vs HEAD auf **identischer** Gate-DB (siehe `FRV40_AB_COUNTERCHECK.md`)
3. **Browser:** Playwright Real-DB — autoritativ in `frv40-browser.csv` / `FRV40_BROWSER.md`

Historische Datei `frv40-results.baseline.csv` bleibt **unverändert**.  
Zusätzlich: `frv40-release-baseline.csv` (Release-Referenz auf aktuellem DB/Host; ersetzt die historische CSV nicht).

## Historische Baseline-Provenienz

| Item | Evidence |
|---|---|
| Datei | `docs/review-mvp/bench/frv40-results.baseline.csv` |
| Erstmals in Git | `c54ae4ba5b7989c874efb7777e60f9350f86ee9c` (2026-08-15 01:46 +0200) |
| Exakter Generierungs-Commit / DB-Kopie / Host | **NOT_VERIFIED** |
| Methodik der Ära | same-process Cold→Warm (INFERRED aus `bench-frv40.ts` bei c54ae4b) |
| Kennzeichnung | **HISTORICAL / NOT_DIRECTLY_REPRODUCIBLE** |

## groups_provenance — VERIFIED_FIXED

Unverändert belassen. Warm ≤ historische Baseline nach Single-Pass-Fix. Siehe `FRV40_GROUPS_ISOLATE.md`.

## A/B Countercheck (offene Metriken) — VERIFIED

A = `d5013ba` worktree · B = HEAD · gleiche DB · 3× A→B · n=30/Metrik/Zustand

| Metric | A p50 | B p50 | Δ B vs A |
|---|---:|---:|---:|
| gallery | 677 | 653 | **−3.6 %** |
| category_subtree | 390 | 377 | **−3.3 %** |
| category_gallery | 1719 | 1624 | **−5.5 %** |
| focus | 1528 | 1484 | **−2.8 %** |
| facets | 1729 | 1724 | **−0.3 %** |
| status_counts | 5.6 | 5.4 | **−2.7 %** |

**Klassifikation:** `VERIFIED_NO_CODE_REGRESSION`  
Historische CSV-Abweichungen vs aktuelle Messungen sind **kein aktueller P0-Codefehler** gegenüber Review-Base (Fall 1/3).

## Browser (autoritativ — `FRV40_BROWSER.md` / `frv40-browser.csv`)

| Metric | Cold | Warm |
|---|---:|---:|
| time_to_first_grid_ms | **6126** | **6587** |
| Visible thumbs | 54 | 54 |
| DOM nodes after scroll | — | 8818 |
| Long tasks (count) | 0 | 0 |
| rAF frame p95 (ms) | — | 16.8 |
| JS heap (MB) | — | 9.5 |

Lauf-zu-Lauf-Spanne First Grid auf Real-DB typisch **~6–13 s** (frühere Artefakte u. a. ~8.7 / ~12.9 s). Sachlich dokumentiert; keine „schnell“-Bewertung. UX → FRV-47. Virtualisierung bounded.

## Bulk / Write Guard

Bulk 1/100/10k: ~8 ms / ~7 ms / ~788 ms; Undo; **restoreOk=true**. Write nur unter Temp-Root.

## Verdict

**PASS**

- Groups: VERIFIED_FIXED  
- Offene API-Deltas vs historischer CSV: HISTORICAL / NOT_DIRECTLY_REPRODUCIBLE; vs Review-Base: **keine** ungeklärte >20 %-Code-Regression (VERIFIED)  
- Browser-Artefakte konsistent dokumentiert  

## Artefakte

- `frv40-results.baseline.csv` (immutable, historical)
- `frv40-release-baseline.csv` (zusätzliche Release-Referenz)
- `frv40-results.csv`, `frv40-ab-countercheck.csv`, `FRV40_AB_COUNTERCHECK.md`
- `frv40-groups-isolate.csv`, `FRV40_GROUPS_ISOLATE.md`
- `frv40-browser.csv`, `FRV40_BROWSER.md`
