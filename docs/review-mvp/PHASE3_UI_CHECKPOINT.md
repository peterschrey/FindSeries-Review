# Phase-3 UI Checkpoint (FRV-17 … FRV-21)

**Stand:** 2026-08-14  
**Branch:** `review-mvp`  
**Basis:** `30681b9149eb8ea121f657fab79c5e69ce78939a`  
**STOP vor FRV-22**

## 1. Status + DoD

| Task | Status | DoD |
|---|---|---|
| FRV-17 Single View | Done | Desktop-Grid wie Prototyp; Gallery dominant; Shelf horizontal scroll |
| FRV-18 Toolbar/State | Done | Typisierter State; Status-Chips; statuses [] ≠ Default |
| FRV-19 Group Shelf | Done | `/api/groups/query`; Karten mit Counts/Thumbs/Drilldown |
| FRV-20 Galerie+Thumbs | Done | Virtualisierung; Seek-Pages; `GET /api/media/:id/thumb` |
| FRV-21 Kontextspalte | Done | 0/1/N Auswahl + Fokus getrennt; K/R/U/N vorbereitet |

## 2. UI vs Prototyp

Übernommen: dunkles Theme, Toolbar-Chips, Status-Overview-Karten, horizontale Shelf, 3-Spalten-Main, Galerie-Thumbs mit Statusrand. Abweichungen: Sort-Optionen an Backend-Felder; visuelle Similarity-Gruppierung nicht in P0; Kategoriebaum lazy folgt FRV-28.

## 3. Komponentenstruktur

`review/web/src/components/{App,Toolbar,StatusOverview,GroupShelf,LeftNav,Gallery,ContextPanel,ThumbImage}`  
State: `state/reviewState.ts` · Hooks: `hooks/useReviewData.ts` · API: `api/client.ts`

## 4. Filtermodell

`ReviewUiState`: projectId, statuses (undefined|[]|list), q, provenance/categories/uploader, groupBy, sort/dir, drilldown, focusMediaId ≠ selectedIds. Persistenz-Hook vorbereitet (serialisierbar), voll FRV-26.

## 5. Thumbnails

`GET /api/media/:mediaId/thumb?size=` via sharp; Cache unter `REVIEW_THUMB_CACHE_DIR`; Pfade nur aus DB + `REVIEW_MEDIA_ROOTS`; SVG-Placeholder bei Fehler. FRV-38 für tiefere Cache-Optimierung offen.

## 6. Virtualisierung

`@tanstack/react-virtual` zeilenweise; overscan; infinite seek loadMore; DOM nur sichtbarer Puffer.

## 7. Laufzeiten

- Frontend production build: ~0.9 s (vite)
- Sharp thumb generate (800×600 → 160 JPEG): ~7 ms cold (lokaler Spike)
- API thumb cold/warm: Header `X-Thumb-Cache` MISS dann HIT (Integrationstest)

## 8. Tests

Frontend vitest + typecheck/build; Backend inkl. thumbs + bestehende FRV-11–16.

## 9. Restrisiken / Follow-ups

- Finalization nicht in UI; Hardlink-Reconcile vor Prod-Finalize dokumentiert.
- Aggregationen weiterhin langsam (FRV-39).
- Range/Keyboard FRV-22/23.
- Fokus-Karte in Shelf FRV-31.

## 10. SHA

nach Push
