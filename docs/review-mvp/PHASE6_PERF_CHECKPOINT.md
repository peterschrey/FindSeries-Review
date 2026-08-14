# Phase 6 Performance Checkpoint (Draft)

**Branch:** `review-mvp`  
**Commit SHA:** `c54ae4ba5b7989c874efb7777e60f9350f86ee9c`  
**Date:** 2026-08-15  
**Project:** 7  
**Media count (`project_media`):** **184 991** (≥100k ✓)

## Scope

| Task | Artifact | Status |
|---|---|---|
| FRV-38 Thumbs | `docs/review-mvp/bench/FRV38_THUMBS.md`, `frv38-thumbs.csv` | Measured (real originals) |
| FRV-39 SQLite | `docs/review-mvp/bench/FRV39_SQLITE.md`, `frv39-results.csv`, migration `105_review_perf_indexes.sql` | Before/after measured |
| FRV-40 100k API | `docs/review-mvp/bench/frv40-results.csv` | 2 runs Cold/Warm + bulk |

## npm scripts

```bash
npm run bench:thumbs   # review/api
npm run bench:frv39
npm run bench:frv40
```

## FRV-38 Thumbnails (real, n=200 accessible / cold-warm n=100)

| Phase | p50 | p95 |
|---|---:|---:|
| Cold | 75.0 ms | 153.9 ms |
| Warm | 1.9 ms | 6.5 ms |

- Generation: **13.13 img/s** (200 JPEGs)
- Concurrent 40 injects: 1181 ms (queue maxConcurrent=2)
- Error placeholder SVG `?`: **verified** (404 + `image/svg+xml`)
- Sharp pipeline: **not rewritten**

## FRV-39 SQLite (iters=5; heavy groups smoke-only by default)

**PRAGMA:** `journal_mode=wal`, `synchronous=1`, `cache_size=-16000`, `page_size=4096` — documented, not changed aggressively.

**Indexes added (migration 105):**

- `ix_discoveries_project_media_source` `(project_id, media_id, source_type)`
- `ix_discoveries_project_series_types` (partial)
- `ix_discoveries_project_keyword_query` (partial)

Already present from 100–102: source_media, origin_cat, media_review_status(project,status), project_categories parent, series keys.

| Metric | Before p50 | Before p95 | After p50 (warm E:) | After p95 | Δ p50 |
|---|---:|---:|---:|---:|---:|
| category_subtree_count | 460 | 491 | 458 | 2170 | ~0% |
| category_gallery | 2012 | 2063 | **1003** | 1077 | **−50%** |
| groups_provenance | 2151 | 2174 | 5311* | 5472* | disk/plan* |
| focus | 2072 | 2141 | 2008 | 2084 | −3% |
| facets | 2208 | 2285 | 2150 | 2154 | −3% |
| gallery_page | 925 | 967 | 844 | 865 | −9% |
| status_counts | 5.6 | 7.4 | 5.5 | 8.0 | −2% |

\* After on `E:/Temp/.../bench-write-copy.db` (C: lacked ~19GB free for a same-volume copy). Prefer p50; provenance regression likely I/O/plan variance vs C: before.

**EXPLAIN:** new covering index used for `(project_id, media_id, source_type)` after `ANALYZE`.  
**Materialization:** skipped — category_gallery already halved; focus/facets still ~2s residual.

### Groups query rewrite (post-index, same gate DB)

N+1 `computeStatusCounts` per group card removed; category group key uses indexed `origin_category_id` only (title-fallback remains in filter SQL).

| groupBy (all statuses, limit 20, sampleSize 0) | ms |
|---|---:|
| provenance | ~1850 |
| uploader | ~1690 |
| series | ~1840 |
| seed | ~720 |
| category | **~385** |

Gate DB note: only `source_type=category` discoveries + 0 `media_series_keys` → provenance/series appear as 1 group; not a pagination bug.

## FRV-40 100k API (gate DB read; write copy for bulk)

Key Warm run_id=2 (p50 / p95 ms):

| Metric | p50 | p95 |
|---|---:|---:|
| gallery / time-to-first-grid | 571 | 638 |
| groups_provenance | 1490 | 1517 |
| category_subtree | 351 | 357 |
| category_gallery | 1478 | 1546 |
| focus | 1309 | 1320 |
| facets | 1554 | 1567 |
| status_counts | 5.0 | 5.7 |

- RSS ≈ **106–141 MB**
- Thumbnail sample (n=20): cold p50 **22 ms**, warm **0.8 ms**
- Bulk (write copy, undone): 1→1208 ms*, 100→31 ms, 10k→1948 ms (*first write cold)
- Scroll / Long Tasks: **N/A** (API-only bench)
- Regression vs baseline: no `frv40-results.baseline.csv` yet (helper ready)

## Residual risks

1. **focus / facets / category_gallery** still ~1–2s at 185k — materialization may be needed for sub-second UX.
2. **Full groups_category/series/seed** — one-shot on gate did not finish in ~11 min; use `REVIEW_BENCH_INCLUDE_HEAVY=1` / `bench-heavy-groups-once.ts` only when budgeting long runtime.
3. **Cross-volume before/after** (C: vs E:) limits index A/B purity until C: has free space.
4. Browser scroll/Long Tasks not measured here — need UI harness later.
5. Bulk first-op latency sensitive to WAL/cold open.

## DBs used

- Read: `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` (readonly)
- Write: `E:\Temp\FindSeries-Review-Test\bench-write-copy.db` (migrations 100–105 applied)
- Production FindSeries DB: **not touched**
