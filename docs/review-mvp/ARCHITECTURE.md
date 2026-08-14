# Technische MVP-Architektur (FRV-4)

**Status:** Done (FRV-4) · **Stack-Update:** 2026-08-14 (verbindlicher P0-Stack vor Phase 2)  
**Bezug:** `MVP_SPEC.md` §§19–22 · `CURRENT_ARCHITECTURE.md` · Notion FRV-4

## Zielbild

Lokale **Windows**-Lösung: schlankes HTTP-Backend + Browser-Frontend (Single View).  
Bestehende FindSeries-SQLite bleibt Source of Truth. Keine Cloud-Pflicht.

```text
[Browser UI]  <--HTTP JSON-->  [Review Backend]  <--SQLite-->  findseries-v5.db (Kopie/Dev)
   Vite/React/TS                    Node/TS/Fastify
                                      |
                                      +--> Thumbnail-Cache (lokale SSD)
                                      +--> Media-Dateien (lokal oder Junction/externe SSD)
                                      +--> review/shared (gemeinsame API-Verträge)
```

Die PowerShell-Pipeline (`FindSeries.ps1` / Worker) bleibt unverändert und kann parallel laufen (WAL, Locks beachten).

## Stack (verbindliche P0-Entscheidung)

| Schicht | Wahl | Begründung |
|---|---|---|
| Frontend | **Vite + React + TypeScript** | Single View, Virtualisierung, Typsicherheit |
| Backend | **Node.js + TypeScript + Fastify** | Ein P0-Web/API-Stack; klare JSON-API; keine Änderung an `.psm1`-Pipeline |
| SQLite-Treiber (P0) | **better-sqlite3** (bevorzugt), sofern Spike keine Gegengründe zeigt | Synchroner, etablierter Node-Treiber; `busy_timeout` / kurze Transaktionen |
| API-Verträge | **`review/shared/`** – gemeinsame TypeScript Types/Schemas (Request/Response-DTOs) | Frontend und Backend verwenden dieselben Verträge |
| DB | Bestehende SQLite-Datei, Review-Tabellen via Migration | Kein zweites System of Record |
| Auth | Keine (localhost only, Bind `127.0.0.1`) | MVP-Nicht-Ziel Rechteverwaltung |

### Explizit nicht P0

- **Python ist nicht Bestandteil des P0-Web/API-Stacks.**
- Keine FastAPI-/Python-API parallel zum Node-Backend.
- Der gesamte P0-Review (API + UI + Status/Bulk/Undo/Thumbnails) muss **ohne Python** laufen.

### Optional später (P1)

Python darf als **separater P1-Worker** für lokale ML-Aufgaben (z. B. Embeddings/CLIP) eingesetzt werden, **nur wenn** Bedarf besteht. Das ist kein Bestandteil von FRV-11ff P0 und blockiert den P0-Review nicht.

## Prozesse & Ports

| Prozess | Default | Rolle |
|---|---|---|
| `review-api` (Fastify/Node) | `http://127.0.0.1:8787` | API + optional Static UI |
| Vite Dev-Server (optional) | lokal, Proxy auf API | UI-Entwicklung |
| Browser | Systemdefault | UI |
| FindSeries Worker | bestehend (PowerShell) | Discovery/Download – getrennt |

Start/Stop (Ziel, FRV-45 detailliert):

```powershell
# Dev (DB-Kopie!)
.\review\Start-FindSeriesReviewUi.ps1 -DatabasePath 'D:\...\findseries-v5-COPY.db' -Workspace 'C:\FindSeriesV5-Workspace'
# Stop: Ctrl+C bzw. Stop-Skript
```

## Verzeichnisstruktur (neu, additiv)

```text
review/
  api/                 # Backend (Node.js + TypeScript + Fastify)
  web/                 # Frontend (Vite + React + TypeScript)
  shared/              # Gemeinsame API-Verträge (Types / Schemas)
  db/                  # Migrationen / Tests (bereits Phase 1)
  Start-FindSeriesReviewUi.ps1
docs/review-mvp/       # Specs (bereits vorhanden)
```

Keine Umbennenung bestehender `Modules/`-Pipeline-Dateien.

## DB-Zugriff & Schreibverantwortung

| Bereich | Wer schreibt | Wann |
|---|---|---|
| `projects`, `media`, `discoveries`, Downloads, Tasks | nur FindSeries-Pipeline | unverändert |
| Review-Status / Historie (neu) | nur Review-Backend (Node/Fastify) | Bulk/Einzel/Undo |
| Finalisierung (physisch) | separates Backend-Kommando | Dry-Run + Confirm |
| Thumbnails | Review-Backend (Cache-Dateien) | lazy |

**Entwicklung:** ausschließlich DB-**Kopie**. Produktiv-DB (`C:\FindSeriesV5-Workspace\findseries-v5.db`) nie ungefragt beschreiben.

WAL: Backend setzt `busy_timeout`, kurze Transaktionen; keine langen Writer-Locks während Download-Läufen.

## API-Grenzen (P0)

- Listen: cursor/seek-Pagination, nie Full-Dump
- Filter: Status, Suche, Herkunft, Kategorie, Serie, Uploader, Seed, Gruppe/Drilldown, Fokusbeziehung
- Aggregationen: Statuscounts (Gesamt/Ergebnis/Auswahl), Gruppen inkl. Samples
- Mutations: Bulk-Status + Undo (batch_id); Reset auf unreviewed = History + DELETE Current-Zeile
- Fokus-Beziehungen: ohne Fokus keine Fokusgruppen
- Similarity: P1; Endpoint-Platzhalter optional, keine Cloud, kein Python-P0

## Thumbnail-Pfad

- Cache-Root: `{Workspace}\Diagnostics\review-thumbs\` oder konfigurierbar lokal (schnelle SSD)
- Key: deterministisch aus `media_id` + Größe/Version
- Original: `downloads.local_path` / Media-Hash-Store; fehlende Datei → Placeholder
- Erzeugung in P0 über Node (kein Python-Pflichtpfad)

## Read-only Spike (Verifikation)

Ausgeführt gegen Produktiv-DB im Modus `?mode=ro` (kein Schreibzugriff):

| Check | Ergebnis |
|---|---|
| Projekte lesen | u. a. Cat_Dentistry (7), Extended (1), Keyword-Projekte |
| Medien/Counts | media ≈ 305k; project_media ≈ 447k |
| Kategorien | categories ≈ 15.6k; `project_categories` mit Parent/Depth |
| Discoveries | source_types belegt (siehe PROVENANCE.md) |
| Windows | PowerShell + `Tools\sqlite3.exe`; Browser öffnet später `127.0.0.1:8787` |

Spike-Kommando (reproduzierbar):

```powershell
.\Tools\sqlite3.exe "file:C:/FindSeriesV5-Workspace/findseries-v5.db?mode=ro" "SELECT id,name FROM projects;"
```

Vor FRV-11 zusätzlich: kurzer Node/better-sqlite3-Spike (RO-Counts, busy_timeout) – nur wenn Gegengründe gegen better-sqlite3 auftauchen, Treiberwahl dokumentiert ändern.

### Mini-Spike Ergebnis (2026-08-14)

Skript: `review/spike-node-sqlite/` (Node 22 + Fastify 5 + better-sqlite3 11).

Gegen DB-Kopie `findseries-v5-phase1-gate.db` (read-only):

- `busy_timeout=5000`, `query_only=ON`
- Projekt 7 (`Cat_Dentistry`) gelesen
- parametrisierter Media-/project_media-Count OK (`media=305212`)
- Fastify Health-Endpoint auf `127.0.0.1` OK
- Verbindungen sauber geschlossen

**Entscheidung:** better-sqlite3 bleibt verbindlicher P0-Treiber. Keine Treiberfrage offen.

## Nicht in dieser Architektur

- Cloud-Embeddings
- Python/FastAPI als P0-API
- Umbau Explorer-Review (`review_exports`) als UI-Ersatz (Koexistenz bis eigener Task)
- Schreiben auf Produktiv-DB in Dev
