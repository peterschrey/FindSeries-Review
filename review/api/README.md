# Review API (P0)

Node.js + TypeScript + Fastify + better-sqlite3.

## Setup

```bash
cd review/shared && npm install && npm run build
cd ../api && npm install
```

## Databases

| DB | Role |
|---|---|
| `C:\Temp\FindSeries-Review-Test\review-dev-mini.db` | **Default** for Entwicklung, Unit/Integration, Browser-E2E (~8k media) |
| `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` | Full gate copy — **only** Perf / Migration / Real-DB-Acceptance |
| Production `FindSeriesV5-Workspace\findseries-v5.db` | **Never** for writes/tests |

Rebuild mini DB:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File review\db\scripts\New-ReviewDevMiniDatabase.ps1
```

See `docs/review-mvp/REVIEW_DEV_MINI_DB.md`.

## Run

```bash
# Default: review-dev-mini.db
set REVIEW_DB_PATH=C:\Temp\FindSeries-Review-Test\review-dev-mini.db
set REVIEW_DELETE_ROOTS=C:\FindSeriesV5-Workspace\Media
set REVIEW_FINALIZE_LOG_DIR=C:\Temp\FindSeries-Review-Test\finalize-logs
npm run dev
```

## Test / Bench

API unit/integration tests use a **synthetic** SQLite fixture (`createSyntheticReviewDb`).
`npm run bench` defaults to mini DB; set `REVIEW_PERF_DB_PATH` to the gate copy for 100k+ runs.

```bash
npm test
npm run bench
# Explicit full-copy perf:
set REVIEW_PERF_DB_PATH=C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db
npm run bench:frv39
npm run bench:frv40
npm run bench:thumbs
```

### One-command Review release gate (FRV-42)

```powershell
.\scripts\Invoke-ReviewTests.ps1
# or:
npm test
```

CI: `.github/workflows/review-ci.yml` (synthetic DB only).
