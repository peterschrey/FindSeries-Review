# Real-DB Migration Test (FRV-10)

**Stand:** 2026-08-14  
**Branch:** `review-mvp`  
**Ergebnis:** PASS

## Source / Target

| Rolle | Pfad |
|---|---|
| **Source (Produktiv, unverändert)** | `C:\FindSeriesV5-Workspace\findseries-v5.db` |
| **Test target (frische Kopie)** | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-test.db` |

**Source wurde nicht migriert und nicht mit Review-Migrationen beschrieben.**  
Nach dem Test: `schema_migrations` auf der Source enthält **keine** Versionen ≥ 100.

Repo-interne DB-Kopien wurden **nicht** als Real-DB-Nachweis verwendet.

## Backup-Methode

- Konsistentes Online-Backup über die **SQLite Online Backup API**  
  (`Python sqlite3.Connection.backup`, äquivalent zu CLI `.backup main …`).
- **Nicht** verwendet: `Copy-Item` von `.db` / `-wal` / `-shm`.
- Windows-Hinweis: CLI-Form `.backup main <path>` (ohne `main` würde `C:` als DB-Alias fehlinterpretiert).
- Backup-Dauer: **78,8 s** (Start 2026-08-14T19:58:41, fertig ~20:00:00).
- Anschließend auf der Kopie: `PRAGMA quick_check` → **ok** (~3 min).

Während des Backups lief FindSeries mit Schreiblast (`write.lock`); die Kopie ist ein konsistenter Snapshot zum Backup-Zeitpunkt.

## Freier Speicher (vor Backup)

Ca. **27 GB** frei auf `C:` (Quelle ~18,8 GB) – ausreichend für eine vollständige Kopie.

## Core-Counts (Testkopie, vor = nach Migration)

Format: `projects|media|project_media|discoveries|categories|project_categories|downloads`

| Zeitpunkt | Counts |
|---|---|
| Pre-Migration (Testkopie) | `7\|305212\|446882\|1361985\|15640\|18444\|113875` |
| Post-Migration Pass 1 | `7\|305212\|446882\|1361985\|15640\|18444\|113875` |
| Post-Migration Pass 2 | `7\|305212\|446882\|1361985\|15640\|18444\|113875` |

**Core-Counts unverändert.**

Hinweis: Die laufende Produktiv-DB kann danach weiter wachsen (z. B. `downloads`); das belegt Schreibaktivität auf der Source, nicht eine Migration der Source.

## Integrity / FK (Testkopie)

| Check | Pre | Post |
|---|---|---|
| `PRAGMA quick_check` | ok | ok |
| `PRAGMA integrity_check` | ok | ok |
| `PRAGMA foreign_key_check` | 0 rows | 0 rows |

## schema_migrations 100–104

Auf der **Testkopie** nach 2× Apply: `100,101,102,103,104` vorhanden.  
Auf der **Source**: weiterhin ohne 100–104.

Vorhandene Core-Migrationen auf der Source (unverändert): `1,2,11,12,13,30,32,34,42,44,52,62,65`.

## Migrations-Dauer (Testkopie)

**Pass 1 (Indexerzeugung):**

| Migration | Dauer |
|---|---|
| 100_review_status.sql | 33 ms |
| 101_provenance_map.sql | **5313 ms** (Discovery-/Uploader-Indizes) |
| 102_category_graph.sql | 73 ms |
| 103_series_keys.sql | 37 ms |
| 104_similarity_meta.sql | 27 ms |
| **Pass 1 gesamt** | ~6,0 s |

**Pass 2 (Idempotenz):** jeweils ~21–26 ms; gesamt ~0,6 s.

DB-Größe Testkopie nach Migration: ~20,27 GB (leicht über Snapshot durch neue Indizes/Leerseiten).

## Fazit

- Frische Produktiv-Kopie via Online-Backup: **PASS**
- Migration 100–104 2× idempotent: **PASS**
- Core-Counts stabil: **PASS**
- Integrity/FK: **PASS**
- Produktiv-Source ohne Review-Migrationen: **PASS**

Die Test-DB liegt außerhalb des Repositories und wird **nicht** committed.
