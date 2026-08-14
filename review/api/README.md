# Review API (P0)

Node.js + TypeScript + Fastify + better-sqlite3.

## Setup

```bash
cd review/shared && npm install && npm run build
cd ../api && npm install
```

## Run

```bash
# Default DB: C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db
set REVIEW_DB_PATH=C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db
# Semicolon-separated roots required for physical file deletes
set REVIEW_DELETE_ROOTS=C:\FindSeriesV5-Workspace\Media
set REVIEW_FINALIZE_LOG_DIR=C:\Temp\FindSeries-Review-Test\finalize-logs
npm run dev
```

Never point write tests at the production FindSeries DB
(`C:\FindSeriesV5-Workspace\findseries-v5.db`).

## Test / Bench

```bash
npm test
npm run bench
```
