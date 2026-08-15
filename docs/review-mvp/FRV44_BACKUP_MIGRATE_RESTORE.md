# FRV-44 – Backup / Migration / Restore (Final)

**Status:** PASS (awaiting external review)  
**Branch:** `review-mvp`  
**Finished (UTC):** 2026-08-15T10:44:39Z  

## BACKUP

| Item | Value |
|---|---|
| Source | `C:\FindSeriesV5-Workspace\findseries-v5.db` |
| Safety | Online `.backup` via `file:...?mode=ro` only |
| Source unchanged | Size stable across backup window (filesystem check) |
| Baseline (archive) | `E:\Temp\FindSeries-Review-Test\frv44-baseline.db` |
| Backup duration | ~198 s (initial RO backup to E) |
| Baseline size | **20 233 146 368** bytes |

E: is archive / sequential-copy only — no SQLite-intensive checks on E.

## BASELINE VALIDATION (SSD work copy, pre-migration)

Work path used for checks: `C:\Temp\FindSeries-Review-Test\frv44-work.db`  
(sequential copy from E baseline, 175.7 s; C free after copy **27.25 GB**)

| Metric | Value |
|---|---|
| projects | 7 |
| media | 305 212 |
| project_media | 446 882 |
| discoveries | 1 361 985 |
| downloads | 129 787 |
| categories | 15 640 |
| project_categories | 18 444 |
| Core `schema_migrations` | `1,2,11,12,13,30,32,34,42,44,52,62,65` |
| Review table | **absent** |
| Schema fingerprint | `1,2,11,12,13,30,32,34,42,44,52,62,65\|tables=30\|indexes=47` |
| FK | **PASS** (~60.5 s) |
| quick_check | **PASS** (~211.5 s) |
| integrity_check | **PASS** (~302 s, &lt;20 min) |

Artifacts: `docs/review-mvp/bench/frv44-ssd-baseline-snapshot.json`

## MIGRATION (same SSD work DB)

| Item | Result |
|---|---|
| Versions | **100–105** exact |
| Core leak | **0** |
| Core migrations unchanged | yes |
| Idempotent 2nd apply | yes (~ms) |
| Size before → after | 20 233 146 368 → 20 363 804 672 |
| Post FK / quick | **PASS** / **PASS** |

No post-migration full `integrity_check` (baseline integrity already PASS).

## SMOKE

| Item | Result |
|---|---|
| Coverage | Projects, Gallery, Categories, Groups, Focus |
| Media | **#1** |
| Sequence | sparse-unreviewed → unsure → Undo → **sparse-unreviewed** |
| Physical finalize | none |

## RESTORE

| Item | Value |
|---|---|
| Method | Sequential copy E baseline → `C:\Temp\FindSeries-Review-Test\frv44-restored.db` |
| Duration | **175.1 s** |
| Size match | yes (20 233 146 368) |
| Counts vs snapshot | **identical** |
| Core migrations | **identical** |
| Schema fingerprint | **exact match** |
| `user_version` / `page_size` | `0` / `4096` (documented on restored) |
| Review 100–105 | **not present** (no review tables) |
| Media #1 | baseline sparse (no review tables) |
| FK / quick | **PASS** / **PASS** |

Negative proof: restored DB does **not** contain Work migration/smoke state.

## STORAGE (after successful restore cleanup)

| Path | Role |
|---|---|
| `E:\Temp\FindSeries-Review-Test\frv44-baseline.db` | kept baseline archive |
| `E:\Temp\FindSeries-Review-Test\archive\findseries-v5-phase1-gate.db` | kept (return to SSD only for FRV-40) |
| `E:\Temp\FindSeries-Review-Test\archive\findseries-v5-phase1-test.db` | kept archive |
| `C:\Temp\FindSeries-Review-Test\review-dev-mini.db` | kept mini |
| `C:\...\frv44-work.db` | deleted after evidence |
| `C:\...\frv44-restored.db` | deleted after PASS |

Gate DB is **not** auto-copied back to C.

## Repro scripts

- `review/db/scripts/Invoke-Frv44BackupMigrateRestoreGate.ps1` (full gate; prefer SSD workflow)
- `review/db/scripts/Invoke-Frv44SsdWorkPhases.ps1` (Phases B–D)
- `review/db/scripts/Invoke-Frv44RestoreVerify.ps1` (restore compare)
- `review/api/scripts/frv44-review-smoke.mjs`
- Prod guard in `review/db/Invoke-ReviewMigrations.ps1`

## Machine reports

- `docs/review-mvp/bench/frv44-phase-a-copy.json`
- `docs/review-mvp/bench/frv44-ssd-baseline-snapshot.json`
- `docs/review-mvp/bench/frv44-ssd-interim-report.json`
- `docs/review-mvp/bench/frv44-evidence-checklist.json`
- `docs/review-mvp/bench/frv44-restore-copy.json`
- `docs/review-mvp/bench/frv44-restore-compare.json`
- `docs/review-mvp/FRV44_SSD_INTERIM.md`
