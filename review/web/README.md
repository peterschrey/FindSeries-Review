# Review Web (P0)

Vite + React + TypeScript. Proxies `/api` → `http://127.0.0.1:8787`.

```bash
cd review/shared && npm install && npm run build
cd ../api && npm install && npm run dev
# other terminal:
cd review/web && npm install && npm run dev
```

Env for API thumbs:

```
REVIEW_MEDIA_ROOTS=C:\FindSeriesV5-Workspace\Media
REVIEW_THUMB_CACHE_DIR=C:\Temp\FindSeries-Review-Test\thumb-cache
```
