# Review Dev Mini Database

**Built:** 2026-08-15T07:48:14.2504680Z  
**Script:** `review/db/scripts/New-ReviewDevMiniDatabase.ps1`  
**Output:** `C:\Temp\FindSeries-Review-Test\review-dev-mini.db`

## Role

| DB | Use |
|---|---|
| `review-dev-mini.db` | **Default** for Entwicklung, Unit/Integration, Browser-E2E |
| Full gate / 100k+ copy (`findseries-v5-phase1-gate.db` etc.) | **Only** explicit Performance-, Migration- oder Real-DB-Acceptance-Tests |
| Production `FindSeriesV5-Workspace\findseries-v5.db` | **Never** for writes/tests |

## Builder hardening

- Source ATTACH via `file:…?mode=ro` (no WAL/write on gate copy)
- Fail-closed: source only under `C:\Temp\FindSeries-Review-Test` or `E:\Temp\FindSeries-Review-Test`
- Production path hard-rejected
- **Sparse unreviewed:** missing `media_review_status` row = unreviewed (`sparse_unreviewed_p7` ≈ 6400+); **no** explicit `unreviewed` seed rows
- Multi-undo fixture: batches `dev-mini-undo-A` (keep) → `dev-mini-undo-B` (unsure) on one media
- `media_series_keys`: empty (gate also 0); P0 series uses discovery fallback; materialized keys covered by synthetic tests

## Size

| | Bytes | Human |
|---|---:|---|
| Source (before) | 20306485248 | 18.91 GB |
| Mini (after) | 311246848 | 296.83 MB |

## Row counts (main tables)

| Table | Before (source) | After (mini) |
|---|---:|---:|
| `projects` | 7 | 7 |
| `media` | 305212 | 8000 |
| `project_media` | 446882 | 26276 |
| `discoveries` | 1361985 | 256899 |
| `downloads` | 117827 | 5857 |
| `categories` | 15640 | 15640 |
| `project_categories` | 18444 | 18444 |
| `media_review_status` | 0 | 516 |
| `media_review_history` | 101000 | 5517 |
| `media_review_batches` | 10 | 15 |
| `media_series_keys` | 0 | 0 |
| `review_provenance_type_map` | 13 | 13 |

## Integrity

- `PRAGMA foreign_key_check`: PASS (empty)
- `PRAGMA quick_check`: PASS (ok)

## Representativeness (post-build probes)

```
series_keys|119
seed_parents|53
uploaders|2015
null_uploaders|150
multi_project_media|6719
origin_cat|8312
fallback_cat|26339
status_keep|170
status_reject|171
status_unsure|175
status_unreviewed_explicit|0
sparse_unreviewed_p7|6419
undo_chain_media|4
deep_pc|10393
source_types|13
reason_meta|cat_fallback=532,deep_cat_origin=1192,fill_p14=690,fill_p7=1468,has_download=683,multi_project=418,multi_provenance=998,parent_fk=6,range_p7=800,seed_child=399,seed_parent=2,series=598,uploader=64,uploader_null=150
series_keys_note|empty; P0 series uses discovery fallback + synthetic coverage
```

Sampling is stratified (deep categories, origin + source_value fallback, multi-provenance, series, seeds, uploaders/null, multi-project membership, consecutive ranges, seeded four review statuses + batch/history). **Not** first-N media IDs.

## Rebuild

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File review\db\scripts\New-ReviewDevMiniDatabase.ps1
```

## Env default

`REVIEW_DB_PATH=C:\Temp\FindSeries-Review-Test\review-dev-mini.db`  
Perf benches: set `REVIEW_DB_PATH` / `REVIEW_PERF_DB_PATH` to the full gate copy explicitly.
