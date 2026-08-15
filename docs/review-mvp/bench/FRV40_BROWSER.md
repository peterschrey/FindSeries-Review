# FRV-40 Browser Benchmark (Real-DB)

**Date:** 2026-08-15T18:43:51.107Z
**DB:** `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` (C: gate copy; not production)
**Project:** 7
**Result total (UI):** Cold 184991 · Warm 184991
**Stack:** FRV-46 static dist + buffered /api proxy

## Metrics

| Metric | Cold | Warm |
|---|---:|---:|
| time_to_first_grid_ms | 6125.6 | 6587.1 |
| Visible thumbs in DOM | 54 | 54 |
| DOM nodes (after scroll) | — | 8818 |
| Long tasks (count) | 0 | 0 |
| Long tasks (max ms) | 0.0 | 0.0 |
| rAF frame p95 (ms) | — | 16.8 |
| JS heap used (MB) | — | 9.5 |

## Acceptance checks

- Result total > 100000: **YES**
- DOM thumbs << media count (virtualized): **YES** (54 thumbs)
- No 100k DOM nodes: **YES** (8818)

## Notes

- Thumbs are SVG placeholders (no E: media I/O) — grid/scroll still exercise Real-DB gallery APIs.
- Long-task observer is Chromium-only; may be empty if none >50ms.
- API `time_to_first_grid` in frv40-results.csv remains a gallery-proxy note; **this browser metric is authoritative**.
