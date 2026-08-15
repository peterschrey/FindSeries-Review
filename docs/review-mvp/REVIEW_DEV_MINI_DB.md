# Review Dev Mini Database

**Built:** 2026-08-15T07:23:10.2430333Z  
**Script:** `review/db/scripts/New-ReviewDevMiniDatabase.ps1`  
**Output:** `C:\Temp\FindSeries-Review-Test\review-dev-mini.db`

## Role

| DB | Use |
|---|---|
| `review-dev-mini.db` | **Default** for Entwicklung, Unit/Integration, Browser-E2E |
| Full gate / 100k+ copy (`findseries-v5-phase1-gate.db` etc.) | **Only** explicit Performance-, Migration- oder Real-DB-Acceptance-Tests |
| Production `FindSeriesV5-Workspace\findseries-v5.db` | **Never** for writes/tests |

## Size

| | Bytes | Human |
|---|---:|---|
| Source (before) | 20306485248 | 18.91 GB |
| Mini (after) | 311263232 | 296.84 MB |

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
| `media_review_status` | 0 | 565 |
| `media_review_history` | 101000 | 5565 |
| `media_review_batches` | 10 | 14 |
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
status_unsure|174
status_unreviewed|50
deep_pc|10393
source_types|13
reason_meta|cat_fallback=532,deep_cat_origin=1192,fill_p14=690,fill_p7=1468,has_download=683,multi_project=418,multi_provenance=998,parent_fk=6,range_p7=800,seed_child=399,seed_parent=2,series=598,uploader=64,uploader_null=150
```

Sampling is stratified (deep categories, origin + source_value fallback, multi-provenance, series, seeds, uploaders/null, multi-project membership, consecutive ranges, seeded four review statuses + batch/history). **Not** first-N media IDs.

### Checklist vs requirements

| Requirement | Mini result |
|---|---|
| Cat_Dentistry + deep category branches | project 7 + `deep_pc` ≥2 depth nodes kept |
| origin_category_id discoveries | 8312 rows |
| source_value fallback discoveries | 26339 rows |
| multi provenance types | 13 distinct `source_type`, 998 multi-provenance media |
| ≥10 series | **119** distinct series keys |
| ≥5 seeds | **53** distinct `parent_media_id` |
| ≥5 uploaders | **2015** |
| NULL/empty uploaders | **150** |
| multi `project_media` membership | **6719** media |
| all four review statuses | keep/reject/unsure/unreviewed seeded + history/batches |
| consecutive range | 800 media (`range_p7`) |
| FK / quick_check | PASS |

## Runtime comparison (`npm run bench`)

| Metric | Full gate (~19 GB, earlier) | Mini (~297 MB, now) |
|---|---:|---:|
| Gallery page1 limit 100 | ~9–1200 ms (warm/cold) | **22 ms** |
| Gallery + category filter | ~1.9–3.0 s | **70 ms** |
| Groups provenance | ~1.7–3.3 s | **90 ms** |
| Focus | ~1.8 s | **43 ms** |
| Bulk ~7–10k + undo | ~300–115000 ms (full) | **165 / 175 ms** |
| Whole `npm run bench` wall | tens of seconds–minutes | **~1.5 s** |
| `npm test` (synthetic) | — | **~11 s**, 64/64 PASS |

## Rebuild

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File review\db\scripts\New-ReviewDevMiniDatabase.ps1
```

## Env default

`REVIEW_DB_PATH=C:\Temp\FindSeries-Review-Test\review-dev-mini.db`  

Perf benches (FRV-38/39/40): set **`REVIEW_PERF_DB_PATH`** to the full gate copy — they do **not** follow the mini default.

