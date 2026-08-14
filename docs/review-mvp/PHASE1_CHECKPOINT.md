# Phase-1 Checkpoint (FRV-1 … FRV-10)

**Stand:** 2026-08-14 (finaler Gate vor FRV-11)  
**Branch:** `review-mvp`  
**Status:** **READY FOR FRV-11**

### Stack (verbindlich)

- Frontend: Vite + React + TypeScript  
- Backend: Node.js + TypeScript + Fastify  
- SQLite: **better-sqlite3** (Mini-Spike PASS)  
- Verträge: `review/shared/`  
- Kein Python/FastAPI im P0-Web/API-Stack

### Gate-Nachweise (dieser Stand)

| Punkt | Ergebnis |
|---|---|
| `review_schema_migrations` statt Core | PASS – Real-Kopie 2× Apply, Core unverändert |
| Category-Fallback (normalized source_value + project membership) | PASS – siehe `CATEGORY_GRAPH.md` |
| Provenance Unknown-Erfassung | PASS |
| Merge gleicher Status → neuere komplette Zeile | PASS |
| Series ≥10 Assert | PASS |
| Node/better-sqlite3 Spike | PASS |

## 1. Tasks FRV-1 … FRV-10

| ID | Task | Status | DoD |
|---|---|---|---|
| FRV-1 … FRV-4 | Phase 0 Specs | Done | Ja |
| FRV-5 | Review-Tabellen | Done | Ja (`review_schema_migrations`) |
| FRV-6 | Provenienz | Done | Ja (real ≥50) |
| FRV-7 | Kategoriegraph | Done | Ja + Fallback-Semantik |
| FRV-8 | Serien | Done | Ja (≥10 Assert) |
| FRV-9 | Similarity P1 | Done | Ja |
| FRV-10 | Migrationen | Done | Ja (`REAL_DB_MIGRATION_TEST.md`) |

## 2. Wichtige Pfade

- Docs: `docs/review-mvp/*`
- Migrationen: `review/db/migrations/100–104` → `review_schema_migrations`
- Runner: `review/db/Invoke-ReviewMigrations.ps1`
- Spike: `review/spike-node-sqlite/`
- Merge: `Modules/FindSeries.Database.psm1`

## 3. Category-Semantik für FRV-11

1. `origin_category_id` wenn vorhanden  
2. sonst `lower(source_value)=categories.normalized_title` **und** Knoten in `project_categories`  
3. nur eindeutige Matches; sonst keine Zuordnung  
4. immer `DISTINCT media_id`

## 4. Nächster Schritt

**FRV-11 starten** (Galerie-Query API auf Node/Fastify/TS + better-sqlite3).
