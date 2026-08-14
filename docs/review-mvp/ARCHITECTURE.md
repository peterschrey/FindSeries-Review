# Technische MVP-Architektur (FRV-4)

**Status:** Done (FRV-4)  
**Bezug:** `MVP_SPEC.md` §§19–22 · `CURRENT_ARCHITECTURE.md` · Notion FRV-4

## Zielbild

Lokale **Windows**-Lösung: schlankes HTTP-Backend + Browser-Frontend (Single View).  
Bestehende FindSeries-SQLite bleibt Source of Truth. Keine Cloud-Pflicht.

```text
[Browser UI]  <--HTTP JSON-->  [Review Backend]  <--SQLite-->  findseries-v5.db (Kopie/Dev)
                                      |
                                      +--> Thumbnail-Cache (lokale SSD)
                                      +--> Media-Dateien (lokal oder Junction/externe SSD)
```

Die PowerShell-Pipeline (`FindSeries.ps1` / Worker) bleibt unverändert und kann parallel laufen (WAL, Locks beachten).

## Stack (P0-Entscheidung)

| Schicht | Wahl | Begründung |
|---|---|---|
| Backend | Lokaler HTTP-Server unter Windows (Python FastAPI *oder* Node; **erste Implementierung: Python 3 + FastAPI**, weil SQLite/Read-only Spike und Thumbnails mit Stdlib/Pillow einfach) | Klar getrennte API, keine Änderung an `.psm1`-Pipeline |
| Frontend | Statische SPA (Vite + React/TS) ausgeliefert vom Backend oder `file`/localhost | Passt zur Single View / Virtualisierung |
| DB | Bestehende SQLite-Datei, Review-Tabellen via Migration | Kein zweites System of Record |
| Auth | Keine (localhost only, Bind `127.0.0.1`) | MVP-Nicht-Ziel Rechteverwaltung |

Alternative Node ist erlaubt, wenn ein späterer Task das begründet – **kein** Parallelbau beider Stacks.

## Prozesse & Ports

| Prozess | Default | Rolle |
|---|---|---|
| `review-api` | `http://127.0.0.1:8787` | API + optional Static UI |
| Browser | Systemdefault | UI |
| FindSeries Worker | bestehend | Discovery/Download – getrennt |

Start/Stop (Ziel, FRV-45 detailliert):

```powershell
# Dev (DB-Kopie!)
.\review\Start-FindSeriesReviewUi.ps1 -DatabasePath 'D:\...\findseries-v5-COPY.db' -Workspace 'E:\Temp\FindSeriesV5-Workspace'
# Stop: Ctrl+C bzw. Stop-Skript
```

## Verzeichnisstruktur (neu, additiv)

```text
review/
  api/                 # Backend
  web/                 # Frontend
  Start-FindSeriesReviewUi.ps1
docs/review-mvp/       # Specs (bereits vorhanden)
```

Keine Umbennenung bestehender `Modules/`-Pipeline-Dateien.

## DB-Zugriff & Schreibverantwortung

| Bereich | Wer schreibt | Wann |
|---|---|---|
| `projects`, `media`, `discoveries`, Downloads, Tasks | nur FindSeries-Pipeline | unverändert |
| Review-Status / Historie (neu) | nur Review-Backend | Bulk/Einzel/Undo |
| Finalisierung (physisch) | separates Backend-Kommando | Dry-Run + Confirm |
| Thumbnails | Review-Backend (Cache-Dateien) | lazy |

**Entwicklung:** ausschließlich DB-**Kopie**. Produktiv-DB (`E:\Temp\FindSeriesV5-Workspace\findseries-v5.db`) nie ungefragt beschreiben.

WAL: Backend setzt `busy_timeout`, kurze Transaktionen; keine langen Writer-Locks während Download-Läufen.

## API-Grenzen (P0)

- Listen: cursor/seek-Pagination, nie Full-Dump
- Filter: Status, Suche, Herkunft, Kategorie, Serie, Uploader, Seed, Gruppe/Drilldown, Fokusbeziehung
- Aggregationen: Statuscounts (Gesamt/Ergebnis/Auswahl), Gruppen inkl. Samples
- Mutations: Bulk-Status + Undo (batch_id)
- Fokus-Beziehungen: ohne Fokus keine Fokusgruppen
- Similarity: P1; Endpoint-Platzhalter optional, keine Cloud

## Thumbnail-Pfad

- Cache-Root: `{Workspace}\Diagnostics\review-thumbs\` oder konfigurierbar lokal (schnelle SSD)
- Key: deterministisch aus `media_id` + Größe/Version
- Original: `downloads.local_path` / Media-Hash-Store; fehlende Datei → Placeholder

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
.\Tools\sqlite3.exe "file:E:/Temp/FindSeriesV5-Workspace/findseries-v5.db?mode=ro" "SELECT id,name FROM projects;"
```

## Nicht in dieser Architektur

- Cloud-Embeddings
- Umbau Explorer-Review (`review_exports`) als UI-Ersatz (Koexistenz bis eigener Task)
- Schreiben auf Produktiv-DB in Dev
