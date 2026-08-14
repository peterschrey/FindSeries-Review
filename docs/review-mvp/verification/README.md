# Browser / Viewport Verification (Phase 4)

Reproduzierbar:

```bash
# API
cd review/api
set REVIEW_DB_PATH=C:\Temp\FindSeries-Review-Test\findseries-phase4-ui.db
npm run dev

# Web
cd review/web
npm run dev
node scripts/browser-smoke.mjs
```

Artefakte:

- `phase4-ui-1920x1080.png`
- `phase4-ui-2560x1440.png`
- `phase4-ui-scrolled.png`
- `BROWSER_SMOKE.json`

Visuell gegen `docs/review-mvp/prototypes/review-mvp.html`: dunkles Single-View mit Toolbar, Statuskarten, Shelf, 3-Spalten-Main.

Virtualisierung 100k: `review/web/src/components/Gallery.virtual.test.tsx` (echte `@tanstack/react-virtual` Instanz, DOM-Buffer < 80).
