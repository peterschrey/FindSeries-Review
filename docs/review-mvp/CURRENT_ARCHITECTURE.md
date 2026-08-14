# FindSeries – aktuelle Architektur (Review-MVP-relevant)

Stand: 2026-08-14, Codebasis `5.0.14-hotfix66`, Produktiv-DB nur read-only analysiert.

**Rangfolge:** Fachliches/UX in `MVP_SPEC.md`. Dieses Dokument beschreibt die technische Realität (Code + SQLite) und den verbindlichen Review-P0-Zielstack. Bei Konflikt: dokumentieren, nicht raten.

## Review-MVP Zielstack (P0, vor Phase 2)

Verbindlich laut `ARCHITECTURE.md` (Stack-Update 2026-08-14):

| Schicht | Stack |
|---|---|
| Frontend | Vite + React + TypeScript |
| Backend | Node.js + TypeScript + Fastify |
| SQLite | better-sqlite3 (bevorzugt, Spike-vorbehaltlich) |
| Verträge | `review/shared/` (gemeinsame TS Types/Schemas) |

Python ist **nicht** Teil des P0-Web/API-Stacks (kein FastAPI). Optionaler P1-ML-Worker später möglich. Phase-2-Code existiert noch nicht.

## Arbeitsumgebung

| Element | Pfad / Hinweis |
|---|---|
| Code (dieses Repo) | `FindSeries-Review` → GitHub `peterschrey/FindSeries-Review` |
| Produktiv-Workspace | `E:\Temp\FindSeriesV5-Workspace` |
| Produktiv-DB | `C:\FindSeriesV5-Workspace\findseries-v5.db` (~19–20 GB, WAL; **nicht** schreiben/migrieren) |
| Medien | `Workspace\Media\` (Hash-Store), Review-Hardlinks unter `Workspace\Review\<slug>\` |
| Config | `Config/local.json` → Workspace-Pfad; Profile in `Config/profiles.json` |

**Regel:** Produktiv-DB nie schreiben. Review-MVP-Entwicklung nur auf DB-Kopien.

## Startpunkte

| Skript | Rolle |
|---|---|
| `FindSeries.ps1` | Orchestrierung Discovery/Metadata/Neighbor/Download |
| `FindSeries.Worker.ps1` | Worker-Prozesse je Stage |
| `Install-FindSeriesV5.ps1` / `New-FindSeriesLocalWorkspace.ps1` | Setup |
| `Sync-FindSeriesReview.ps1` / `Open-FindSeriesReview.ps1` | bestehendes Explorer-Review |
| `Test-FindSeriesV5.ps1` | Selftests |
| `Show-FindSeriesDownloadMonitor.ps1` | Download-Monitor-UI |

Module: `FindSeries.Core`, `.Configuration`, `.Database`, `.Search`, `.Api`, `.Review`.

## SQLite-Schema (Ist)

Versionen in `schema_migrations` (u. a. 1, 2, 11–13, 30, 32, 34, 42, 44, 52, 62, 65). Journal: **WAL**.

Kernentitäten:

- `projects` – Projekte (Slug, Profil, `config_json`)
- `media` – globale Medienidentität (title, page_id, sha1, Uploader, Metadaten)
- `project_media` – Projektzuordnung, Score, `selected`, `download_requested`
- `discoveries` – **Provenienz** (`source_type`, `source_value`, `query_text`, `origin_category_id`, `parent_media_id`); Mehrfachherkunft möglich
- `categories` / `project_categories` – Kategoriegraph (`parent_category_id`, depth, Counts, Queue-Status)
- `search_tasks` / `metadata_tasks` / `neighbor_tasks` / `project_downloads` / `downloads` – Pipelines
- `downloads.local_path` – lokaler Dateipfad nach Download
- `review_exports` – Explorer-Review (Hardlink/Copy, Status `open`/`rejected`/…)
- `media_rejections` – workspaceweite Sperre nach manuellem Löschen im Explorer-Review

Es gibt **noch keinen** Vier-Status-Review (`Unbewertet|Behalten|Löschen|Unsicher`) laut MVP_SPEC. Bestehendes Review ist Explorer-basiert und binär (offen vs. verworfen über `review_exports` / `media_rejections`). Der neue Status ist laut Spec projektbezogen/global und wird in Phase 1 ergänzt – ohne die Explorer-Pfade umzudeuten.

## Gemessene Bestandsgrößen (Produktiv, read-only)

| Menge | Count |
|---|---|
| media | 305 212 |
| project_media | 446 882 |
| discoveries | 1 361 985 |
| downloads done | 97 019 |
| review_exports (open) | 89 643 |
| media_rejections | 0 |
| categories | 15 640 |

Projekte u. a.: `Cat_Dentistry`, `Cat_Dentistry_Extended`, `Cat_Dentistry_Depth3`, Keyword-Projekte.

### Belegte `discoveries.source_type` (keine erfundenen Werte)

| source_type | Count |
|---|---|
| keyword | 406 512 |
| keyword-group | 380 084 |
| category | 368 497 |
| time-neighbour | 123 348 |
| keyword-title | 26 165 |
| filename | 18 557 |
| keyword-group-description | 14 004 |
| neighbor | 13 498 |
| time-series | 6 424 |
| uploader-neighbour | 4 326 |
| depicts-search | 315 |
| keyword-group-filename | 161 |
| filename-series | 94 |

Mapping auf MVP-Herkunftschips erfolgt in FRV-3/FRV-6; nur belegte Typen verwenden.

## Medienpfade

1. Zentral: `downloads.local_path` bzw. Hash-Struktur unter `Media\`
2. Review-Export: `review_exports.review_path` (Hardlink/Copy) + `source_path`
3. Junctions auf externe SSD möglich – Thumbnail-Cache lokal halten (spätere Tasks)

## Bestehende Indizes (Auswahl, review-relevant)

- `ix_discoveries_project_media`, `ux_discovery_identity`
- `ix_project_media_score`, `ix_project_media_updated`, Download-Seed-Indizes
- `ix_media_*` (page_id, sha1, normalized_title, metadata)
- `ix_review_exports_project_status`, `ix_review_exports_media`
- `ux_media_rejections_*`
- `ix_project_categories_queue`

Neue Review-Status-Indizes erst nach konkreten Queries (EXPLAIN) anlegen.

## Bestehendes vs. neues Review

| Heute | Review-MVP |
|---|---|
| Explorer + Hardlinks | integrierte Web-Single-View |
| Löschen = Datei entfernen → Rejection | Status `Löschen` ohne physisches Löschen |
| kein Keep/Unsicher | 4 globale Status + Historie/Undo |
| Sync-Skript | API + UI; Finalisierung getrennt |

**Wichtig:** `review_exports` / `media_rejections` nicht umdeuten, solange kein Task die Migration/Koexistenz spezifiziert.

## Tests / Diagnostik

- `Test-FindSeriesV5.ps1` – umfassende Selftests (Pipeline schützen)
- Monitor-/Performance-Skripte vorhanden
- Keine bestehende Web-UI für den neuen Review-MVP im Code

## Implikationen für den MVP

1. Schema-Erweiterungen nur als neue `schema_migrations`-Versionen.
2. Provenienz aus `discoveries` ableiten; fehlende Typen nicht erfinden.
3. Kategoriegraph aus `project_categories.parent_category_id`.
4. Serie/Uploader aus `media` + Discovery-Typen (`time-series`, `filename-series`, `uploader-neighbour`, …).
5. UI/API neu; PowerShell-Pipeline unverändert lassen.
