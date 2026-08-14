# FRV-39 SQLite Performance

**Date:** 2026-08-14T23:03:24.000Z
**Project:** 7
**Iterations:** 5
**Media count (project_media):** 184991

## PRAGMA (documented, not aggressively changed)

### before


- process RSS (approx): **0.0 MB**

### after

- journal_mode: `wal`
- synchronous: `1`
- cache_size: `-16000`
- mmap_size: `0`
- page_size: `4096`
- temp_store: `0`
- process RSS (approx): **90.4 MB**

## Before / After (p50 / p95 ms)

| Metric | Before p50 | Before p95 | After p50 | After p95 | Δ p50 |
|---|---:|---:|---:|---:|---:|
| category_subtree_count | 460.1 | 490.6 | 458.2 | 2169.8 | -0.4% |
| category_gallery | 2012.2 | 2063.3 | 1002.8 | 1077.4 | -50.2% |
| groups_provenance | 2150.9 | 2174.2 | 5311.1 | 5471.5 | 146.9% |
| groups_category_smoke | 0.5 | 0.7 | 0.5 | 0.9 | 13.3% |
| focus | 2071.7 | 2140.5 | 2007.9 | 2083.7 | -3.1% |
| facets | 2207.7 | 2284.6 | 2149.7 | 2154.3 | -2.6% |
| gallery_page | 925.1 | 967.0 | 843.7 | 864.7 | -8.8% |
| status_counts | 5.6 | 7.4 | 5.5 | 8.0 | -2.0% |
| category_nodes_root | 3.9 | 4.3 | 3.8 | 4.3 | -0.8% |

## Indexes added (migration 105)

See `review/db/migrations/105_review_perf_indexes.sql`.

- `ix_discoveries_project_media_source` — `(project_id, media_id, source_type)`
- `ix_discoveries_project_series_types` — partial series discovery covering
- `ix_discoveries_project_keyword_query` — partial keyword/query_text covering

Already present from 100–102 (no duplication): `ix_discoveries_project_source_media`, `ix_discoveries_project_origin_cat`, `ix_media_review_status_project_status`, `ix_project_categories_parent`, series-key indexes.

Targeted, idempotent `CREATE INDEX IF NOT EXISTS` only — no materialization table in this migration.

## Disk / environment notes

- Before: readonly gate DB on `C:/Temp/...` (same volume as OS).
- After: writable copy on `E:/Temp/.../bench-write-copy.db` (C: lacked free space for a second ~19GB copy).
- After p95 spikes include cold OS-cache / E: I/O; prefer p50 for index comparison.
- Full `groups_category|series|seed` only with `REVIEW_BENCH_INCLUDE_HEAVY=1` (minutes each); default uses provenance + category smoke.

## Residual / later

- `category_gallery` improved ~50% p50 after 105+ANALYZE (≈2.0s → ≈1.0s) but still near 1s — further materialization optional.
- Groups N+1 status counts removed (single aggregation + window samples); category group keys use `origin_category_id` only → category groups ≈385 ms on gate DB.
- focus/facets still ~1.5–2 s warm — candidate for later materialization if UX requires sub-500 ms.
- Full `groups_category|series|seed` only with `REVIEW_BENCH_INCLUDE_HEAVY=1` (minutes each on pre-rewrite path); default uses provenance + category smoke.
- `focus` / `facets` remain ~2.0–2.2s p50 (no clear sub-second win from 105 alone).
- `groups_provenance` slower on E: after-copy (≈5.3s p50) — treat as **disk/plan variance**, not a proven index regression vs C: before; re-check same-volume when free space allows.
- Full `groups_category|series|seed` (limit 20, sampleSize 0): one-shot probe on gate DB did not finish within **~11 minutes** — residual multi-minute; default bench uses smoke only (`REVIEW_BENCH_INCLUDE_HEAVY=1` to opt in). Helper: `scripts/bench-heavy-groups-once.ts`.
- Rebuildable `review_category_media_counts` deferred (indexes first; category_gallery already halved).
- WAL mode retained; no aggressive PRAGMA changes.
- Groups with `sampleSize:0` + `limit:20` used to keep bench runtime reasonable.


## EXPLAIN QUERY PLAN (phase=after, top p95)

Slowest: groups_provenance=5471.5ms, category_subtree_count=2169.8ms, facets=2154.3ms, focus=2083.7ms, category_gallery=1077.4ms

### discoveries by project+media (join path)
```
SEARCH discoveries USING COVERING INDEX ix_discoveries_project_media_source (project_id=? AND media_id=?)
```
### discoveries category origin
```
SEARCH discoveries USING INDEX ix_discoveries_project_origin_cat (project_id=? AND origin_category_id=?)
```
### media_review_status by project
```
SEARCH media_review_status USING COVERING INDEX ix_media_review_status_project_status (project_id=?)
```
### project_categories parent
```
SEARCH project_categories USING COVERING INDEX ix_project_categories_parent (project_id=? AND parent_category_id=?)
```
### discoveries covering media+source_type (migration 105 target)
```
SEARCH discoveries USING COVERING INDEX ix_discoveries_project_media_source (project_id=? AND media_id=? AND source_type=?)
```

## Indexes present (after)

- `ix_discoveries_project_category_source_value`: `CREATE INDEX ix_discoveries_project_category_source_value ON discoveries(project_id, source_value, media_id) WHERE source_type = 'category' AND origin_category_id IS NULL AND source_value IS NOT NULL AND trim(source_value) <> ''`
- `ix_discoveries_project_keyword_query`: `CREATE INDEX ix_discoveries_project_keyword_query ON discoveries(project_id, source_type, query_text, media_id) WHERE query_text IS NOT NULL AND trim(query_text) <> ''`
- `ix_discoveries_project_media`: `CREATE INDEX ix_discoveries_project_media ON discoveries(project_id, media_id)`
- `ix_discoveries_project_media_source`: `CREATE INDEX ix_discoveries_project_media_source ON discoveries(project_id, media_id, source_type)`
- `ix_discoveries_project_origin_cat`: `CREATE INDEX ix_discoveries_project_origin_cat ON discoveries(project_id, origin_category_id, media_id) WHERE origin_category_id IS NOT NULL`
- `ix_discoveries_project_parent`: `CREATE INDEX ix_discoveries_project_parent ON discoveries(project_id, parent_media_id, media_id) WHERE parent_media_id IS NOT NULL`
- `ix_discoveries_project_series_types`: `CREATE INDEX ix_discoveries_project_series_types ON discoveries(project_id, source_type, media_id, source_value, query_text) WHERE source_type IN ('filename-series', 'time-series', 'filename')`
- `ix_discoveries_project_source_media`: `CREATE INDEX ix_discoveries_project_source_media ON discoveries(project_id, source_type, media_id)`
- `ix_media_review_batches_project_time`: `CREATE INDEX ix_media_review_batches_project_time ON media_review_batches(project_id, created_at DESC)`
- `ix_media_review_history_batch`: `CREATE INDEX ix_media_review_history_batch ON media_review_history(batch_id) WHERE batch_id IS NOT NULL`
- `ix_media_review_history_media`: `CREATE INDEX ix_media_review_history_media ON media_review_history(project_id, media_id, id DESC)`
- `ix_media_review_history_project_time`: `CREATE INDEX ix_media_review_history_project_time ON media_review_history(project_id, id DESC)`
- `ix_media_review_status_batch`: `CREATE INDEX ix_media_review_status_batch ON media_review_status(batch_id) WHERE batch_id IS NOT NULL`
- `ix_media_review_status_project_status`: `CREATE INDEX ix_media_review_status_project_status ON media_review_status(project_id, status, media_id)`
- `ix_media_series_keys_group`: `CREATE INDEX ix_media_series_keys_group ON media_series_keys(project_id, strategy, series_key, sequence_no, media_id)`
- `ix_media_series_keys_primary`: `CREATE INDEX ix_media_series_keys_primary ON media_series_keys(project_id, series_key, sequence_no, media_id) WHERE is_primary = 1`
- `ix_project_categories_lease`: `CREATE INDEX ix_project_categories_lease ON project_categories(project_id, lease_until)`
- `ix_project_categories_parent`: `CREATE INDEX ix_project_categories_parent ON project_categories(project_id, parent_category_id, category_id)`
- `ix_project_categories_queue`: `CREATE INDEX ix_project_categories_queue ON project_categories(project_id, status, depth, category_id)`

