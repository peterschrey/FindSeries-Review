# FRV-38 Thumbnail Benchmark

**Date:** 2026-08-14T23:02:57.935Z
**Mode:** real
**N measured (cold/warm):** 100
**N generation rate:** 200
**Size:** 80px
**Media roots:** E:\Temp\FindSeriesV5-Workspace\Media

## Note

Real downloads under E:\Temp\FindSeriesV5-Workspace\Media; accessible=200

## Error placeholder

- status: 404
- content-type: image/svg+xml
- SVG "?" placeholder: **verified**

## Latency

| Phase | n | p50 (ms) | p95 (ms) | mean (ms) |
|---|---:|---:|---:|---:|
| Cold cache | 100 | 75.0 | 153.9 | 81.1 |
| Warm cache | 100 | 1.9 | 6.5 | 2.7 |

## Throughput

- Generation: **200** images in **15234.1 ms** → **13.13 img/s**
- Concurrent (40 parallel injects): **40** ok in **1181.0 ms**
- Sharp pipeline: not rewritten (no measured breakage)

## Residual

- Disk cache only; no CDN.
- Queue caps concurrency (default 2) — intentional for CPU/IO.
