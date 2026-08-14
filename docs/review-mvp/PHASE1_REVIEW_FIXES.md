# Phase-1 Review Fixes (A–N)

**Stand:** 2026-08-14  
**Branch:** `review-mvp`  
**Stop:** weiterhin vor FRV-11

Produktive DB (nur Quelle für Online-Backup / read-only Checks):

`C:\FindSeriesV5-Workspace\findseries-v5.db`

---

## A. Media-Identity-Merge schützt Reviewdaten

**Befund:** `ON DELETE CASCADE` + fehlendes Remapping → stiller Verlust.

**Änderung:** `Get-FsReviewMergeSql` / `Test-FsSqliteTableExists` in `Modules/FindSeries.Database.psm1`. Nur wenn Tabellen existieren. History immer remappen; Status-Priorität `keep > unsure > reject > unreviewed`. Undo-Hinweis: Current-`batch_id` beachten.

**Test:** `review/db/tests/Test-ReviewMediaMerge.ps1`  
**Ergebnis:** PASS (39 Asserts inkl. DB ohne Reviewtabellen)  
**Restrisiko:** gering.

## B. Real-DB-Migration

**Befund:** nur synthetische DB.

**Änderung / Test:** Frische Kopie via SQLite Online Backup API → `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-test.db`; Migration 100–104 2×; Integrity/FK/Counts.

**Ergebnis:** PASS – Details `REAL_DB_MIGRATION_TEST.md`  
**Source unverändert** (keine Versionen ≥100).  
**Restrisiko:** Source wächst unter Download-Last weiter (Counts der Live-DB können nach Snapshot abweichen).

## C. Migration-Backup

**Befund:** `Copy-Item` + WAL/SHM unzureichend.

**Änderung:** `Invoke-ReviewMigrations.ps1` → `.backup main "<path>"` + `quick_check`; Fehler bricht ab. Keine WAL/SHM-Kopie.

**Test:** synthetischer Lauf mit `-Backup`  
**Ergebnis:** PASS  
**Restrisiko:** unter Extremlast CLI ggf. busy – Backup-API alternativ nutzbar.

## D. Provenienz real

**Befund:** `Test-ProvenanceSample.ps1` fehlte.

**Änderung:** Skript erstellt (read-only).

**Test:** ≥50 reale Medien, Projekt Dentist (`project_id=14`).  
**Ergebnis:** PASS – 50 Medien, 49 multi-family, keine unknown `source_type`; CSV unter `C:\Temp\FindSeries-Review-Test\provenance-sample.csv`  
**Restrisiko:** Query-Latenz.

## E. Seed-Semantik

**Befund:** generische query→parent-Reihenfolge falsch für Neighbor.

**Änderung:** Neighbor → `media:<parent_media_id>`; Keyword → normalisierte Query; sonst NULL. Docs + Tests.

**Ergebnis:** PASS  
**Restrisiko:** keines (Backend FRV-11 übernimmt).

## F. Category-Graph real

**Befund:** nur synthetischer Minibaum.

**Änderung:** `Test-CategoryGraphReal.ps1` gegen Cat_Dentistry (`project_id=7`).

**Ergebnis:** PASS – ≥5 Unterbäume mit Media, Union, CTE=unabhängige Stichprobe, Mehrfachzuordnungen 4064, **62,01%** category-discoveries ohne `origin_category_id`. Report: `C:\Temp\FindSeries-Review-Test\category-graph-real.md`  
**Restrisiko:** fehlende origin-IDs begrenzen Präzision.

## G. Serien real

**Befund:** nur synthetische 1,2,10.

**Änderung:** `Test-SeriesReal.ps1`.

**Ergebnis:** PASS – 10 Serien (filename-series, time-series, uploader+Zeit); Natural-vs-Lex-Differenz mehrfach demonstriert. Report: `C:\Temp\FindSeries-Review-Test\series-real.md`  
**Restrisiko:** natürliche 1/2/10-Prefix-Hits auf Produktiv selten (Zero-Padding).

## H. Primary-Series-Invariante

**Befund:** `is_primary` nicht eindeutig.

**Änderung:** UNIQUE partial index `ux_media_series_keys_one_primary`.

**Test:** Phase1-Harness  
**Ergebnis:** PASS  
**Restrisiko:** keines.

## I. Status-Scope

**Befund:** Begrifflichkeit unklar.

**Änderung:** Docs – projektbezogen, global über Filter; `media_rejections` workspaceweit; reject ≠ Rejection-Row.

**Ergebnis:** umgesetzt  
**Restrisiko:** keines.

## J. Sparse unreviewed

**Befund:** Massen-`unreviewed`-Rows drohen.

**Änderung:** Semantik „keine Current-Zeile = unreviewed“; Reset-Vormerkung History + DELETE; Schema-Test löscht Current-Zeile.

**Ergebnis:** umgesetzt  
**Restrisiko:** Backend FRV-15 muss DELETE nutzen.

## K. Zeitformat

**Befund:** gemischte TEXT-Formate.

**Änderung:** kanonisch `YYYY-MM-DDTHH:mm:ss.fffZ` in STATUS_RULES/SCHEMA.

**Ergebnis:** umgesetzt  
**Restrisiko:** Core-Pipeline `Get-FsUtcNowText` (`o`) – Review-API eigene Helper-Funktion.

## L. Similarity-Schema (P1)

**Befund:** zu wenige Test-Embeddings; phash NOT NULL; keine Algorithmus-Version.

**Änderung:** Migration 104 – nullable phash, PK `(media_id,algorithm)`, ready-CHECKs; Test ≥100 Medien / zwei Modelle.

**Ergebnis:** PASS; 104 **nicht** auf Produktiv angewendet  
**Restrisiko:** keines für P0/FRV-11.

## M. Testharness portabel

**Befund:** User-Pfade (`C:\Users\pschr\tmp\...`).

**Änderung:** Fixture im Repo; Parameter `SourceDatabasePath`/`SchemaDump`; relative Defaults; Exitcodes.

**Ergebnis:** PASS  
**Restrisiko:** Fixture muss versioniert bleiben.

## N. Rollback

**Befund:** Core-Indizes 101/102 fehlten im SQL-Rollback.

**Änderung:** `ROLLBACK_100_104.sql` droppt Indizes; Warnung; Backup-Restore bevorzugt.

**Ergebnis:** umgesetzt  
**Restrisiko:** SQL-Rollback bleibt destruktiv.

---

## Abschluss (erste Korrekturschleife)

Synthetische Tests PASS; Real-Verify PASS; Real-DB-Migration PASS.

---

## Gate vor FRV-11 (2026-08-14)

### 1. `review_schema_migrations`

**Befund:** Review-Versionen in Core `schema_migrations` → Kollisionsrisiko.  
**Änderung:** eigene Tabelle; Runner prüft nur dort; Core-Fingerprint unverändert.  
**Test:** frische Kopie `findseries-v5-phase1-gate.db`, 2× Apply.  
**Ergebnis:** PASS (`100–104` nur in Review-Tabelle; Leak=0).

### 2. Category-Fallback

**Befund:** 62 % null `origin_category_id`.  
**Messung:** 133 917 null-Zeilen; 133 488 eindeutig via `normalized_title`; 0 mehrdeutig; 429 unresolved; 40 486 davon im Projektbaum.  
**Strategie:** origin zuerst; sonst `lower(source_value)=normalized_title` + `project_categories`; keine Erfindung. Indizes in Migration 101.  
**Test:** `Test-CategoryFallbackReal.ps1` – 5 Unterbäume, Union, EXPLAIN; Subtree-Queries ~0,75 s.  
**Ergebnis:** PASS – Semantik in `CATEGORY_GRAPH.md`.

### 3. Provenance Unknown

**Befund:** `$family` vor Zuweisung im else.  
**Änderung:** if/else mit explizitem `unknown.Add`.  
**Ergebnis:** PASS (keine Unknowns im Sample; Ausgabe eindeutig).

### 4. Merge gleicher Status

**Befund:** `changed_at=MAX` bei gemischten Metadaten.  
**Änderung:** bei gleichem Status gewinnt die zeitlich neuere **komplette** Current-Zeile.  
**Test:** same-newer-dup / same-newer-surv.  
**Ergebnis:** PASS (44 Asserts gesamt).

### 5. Series Assert / portable Pfade

**Änderung:** `seriesNo < 10` → throw; Legacy-User-Pfad entfernt.  
**Ergebnis:** PASS (10 Serien).

### 6. Node Spike

**Ergebnis:** better-sqlite3 + Fastify RO-Spike PASS → Treiber verbindlich.

---

## Abschluss Gate

Alle Gate-Punkte PASS.  
**READY FOR FRV-11** (nicht in diesem Commit gestartet).
