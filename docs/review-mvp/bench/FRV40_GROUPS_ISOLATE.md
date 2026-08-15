# FRV-40 groups_provenance isolation

**Date:** 2026-08-15T17:40:35.791Z
**DB:** `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db`
**Project:** 7 · media=184991
**Baseline Warm p50 (reference):** 1490.41 ms

## Method A — same process / one connection (baseline-compatible)

| Phase | p50 | p95 |
|---|---:|---:|
| Cold | 1377.6 | 1378.6 |
| Warm | 1397.9 | 1468.9 |
| Standalone ×20 | 1353.1 | 1555.4 |

Δ Warm vs baseline: **-6.2%**

## Method B — fresh child process (supplemental)

| Phase | p50 | p95 |
|---|---:|---:|
| Cold child | 1170.7 | 1334.7 |
| Warm child | 1172.2 | 1577.5 |

Δ Warm vs baseline: **-21.4%**

## Classification

**VERIFIED_FIXED**

Same-process and child Warm at or faster than baseline Warm after targeted fix (VERIFIED). Prior >20% flag was a real multi-scan regression, now closed.
