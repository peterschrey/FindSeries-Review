# FRV-44 SSD Interim Report (pre-restore)

**Status:** PASS - ready for restore phase
**Finished (UTC):** 2026-08-15T10:26:09.2078411Z

## Phase A Copy
- Source: `E:\Temp\FindSeries-Review-Test\frv44-baseline.db`
- Dest: `C:\Temp\FindSeries-Review-Test\frv44-work.db`
- Seconds: 175.7
- Bytes: 20233146368
- C free after copy: 27.25 GB

## Phase B Baseline (pre-migration)
| Metric | Value |
|---|---|
| Size | 20233146368 |
| projects | 7 |
| media | 305212 |
| project_media | 446882 |
| discoveries | 1361985 |
| downloads | 129787 |
| categories | 15640 |
| project_categories | 18444 |
| core schema_migrations | 1,2,11,12,13,30,32,34,42,44,52,62,65 |
| review_schema_migrations | (none) |
| schema fingerprint | 1,2,11,12,13,30,32,34,42,44,52,62,65|tables=30|indexes=47 |
| foreign_key_check | PASS (60.5s) |
| quick_check | PASS (211.5s) |
| integrity_check | PASS (302s) |

## Phase C Migration
- review_schema_migrations: **100,101,102,103,104,105**
- core unchanged: **True**
- leaked into core: **0**
- idempotent second apply: yes
- seconds: 10.3
- post FK: PASS
- post quick: PASS

## Phase D Smoke
```
{"ok":true,"projects":7,"galleryTotal":184991,"categoryNodes":1385,"groups":3,"focusRelations":6,"smokeMediaId":1,"priorStatus":"sparse-unreviewed","afterUndo":"sparse-unreviewed","undoRestored":1,"sparseRestored":true}
```

## Space
- C free now: **27.15 GB**
- Work DB path/size: `C:\Temp\FindSeries-Review-Test\frv44-work.db` / 20363804672 bytes

## Next
Restore phase not started. Work DB retained.
