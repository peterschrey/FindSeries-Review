# Real-DB Migration Test (FRV-10)

**Stand:** 2026-08-14 (Gate: `review_schema_migrations`)  
**Branch:** `review-mvp`  
**Ergebnis:** PASS

## Source / Target

| Rolle | Pfad |
|---|---|
| **Source (Produktiv, unverändert)** | `C:\FindSeriesV5-Workspace\findseries-v5.db` |
| **Test target (frische Kopie)** | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` |

**Source wurde nicht migriert.** Core `schema_migrations` auf der Source bleibt ohne Review-Versionen.  
Review-Versionen liegen **nur** in `review_schema_migrations` (nie in Core `schema_migrations`).

## Backup-Methode

- SQLite Online Backup API (`Python sqlite3.Connection.backup`, äquivalent `.backup main`)
- Dauer Backup: ~115 s; danach `PRAGMA quick_check` → **ok**
- Kein `Copy-Item` von wal/shm

## Versionierung

| Tabelle | Inhalt nach Test |
|---|---|
| Core `schema_migrations` | unverändert: `1,2,11,12,13,30,32,34,42,44,52,62,65` |
| `review_schema_migrations` | `100,101,102,103,104` |
| Leak Core≥100 | **0** |

## Core-Counts (Testkopie, vor = nach, 2× Apply)

`7|305212|446882|1361985|15640|18444|117827` — unverändert.

## Integrity

| Check | Ergebnis |
|---|---|
| quick_check | ok |
| foreign_key_check | 0 rows |

## Timings Pass 1

| Migration | ms |
|---|---|
| 100 | 94 |
| 101 | 4999 |
| 102 | 74 |
| 103 | 77 |
| 104 | 98 |

Pass 2 (Idempotenz): jeweils ~20–26 ms.

## Fazit

Frische Produktiv-Kopie + Review-Migrationen über `review_schema_migrations` **PASS**. Produktiv-Source unberührt.
