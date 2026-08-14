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
npm run dev
```

## Test / Bench

```bash
npm test
npm run bench
```

Never point write tests at the production FindSeries DB.
