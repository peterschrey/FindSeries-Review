# FRV-46 — Real-DB Acceptance (Cat_Dentistry)

**Status:** Testing (nicht Done)  
**Verdict:** **PASS WITH DEVIATION**  
**Date:** 2026-08-15

## Evidence classes

| Class | Meaning |
|---|---|
| VERIFIED | gemessen / SQL↔API gegengeprüft in diesem Lauf |
| REPORTED | aus Fixture/DB-Lage dokumentiert, nicht erfunden |
| INFERRED | aus Messdaten abgeleitet |
| NOT_VERIFIED | fehlt / nicht gemessen |
| DATA_GAP | Feature-Pfad vorhanden, reale Datenlage unzureichend |
| NOT_AVAILABLE | Datentyp/Pfad auf dieser DB nicht vorhanden (nicht erfunden) |

## DB provenance

| Item | Value | Evidence |
|---|---|---|
| Produktiv-DB | `C:\FindSeriesV5-Workspace\findseries-v5.db` | **nie angefasst** |
| Archivquelle | `E:\Temp\FindSeries-Review-Test\archive\findseries-v5-phase1-gate.db` (20 306 485 248 B) | VERIFIED vorhanden, unverändert belassen |
| Arbeit (SSD) | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` | VERIFIED Kopie sequentiell, Größenmatch |
| Project (Haupt) | **7 / Cat_Dentistry** | VERIFIED |
| Medien (`project_media`) | **184 991** | VERIFIED |
| Review migrations | **100–105** | VERIFIED |
| Core `schema_migrations` | unverändert | VERIFIED |
| `PRAGMA foreign_key_check` / `quick_check` | OK | VERIFIED |

Maschinenlesbar: `docs/review-mvp/bench/frv46-acceptance.json`

## Commands

```powershell
# Finaler Acceptance-Pfad (API/SQL → Browser → Cleanup):
npm run test:frv46

# Diagnose ohne Browser:
.\scripts\Invoke-Frv46RealDbAcceptance.ps1 -SkipBrowser

# Nur Browser (nach Build):
npm --prefix review/web run test:frv46
```

`-SkipBrowser` ist **nicht** der finale Gate-Pfad.

## Workflow A — Kategorieast

| Field | Value |
|---|---|
| Parent | **14367** `Category:Smiling men in the United States` |
| Real children | 33 |
| Descendants | 41 |
| SQL exact / subtree | 780 / 1621 |
| API/UI result (unreviewed+unsure) | 1621 |
| Evidence | **VERIFIED** (API/SQL + Browser) |

## Workflow B — Herkunft / Provenienz

| Field | Value |
|---|---|
| Types in Cat_Dentistry | **nur** `category` (184 991 Medien) |
| category provenance | **VERIFIED** |
| Zweiter Provenienztyp | **NOT_AVAILABLE** (nicht erfunden) |
| GroupCard → Drilldown | 184 991 MATCH |
| Evidence | **VERIFIED** (category) + **NOT_AVAILABLE** (zweiter Typ) |

## Workflow C — Serie

### C1 Cat_Dentistry (Hauptprojekt)

| Field | Value |
|---|---|
| `media_series_keys` | 0 |
| filename-/time-series discoveries | 0 |
| Genutzter Bucket | `(ohne Serie)` total **184 991** |
| Pagination | overlap 0, monotonic ASC |
| Named-series journey | **DATA_GAP** — kein named Series in Cat_Dentistry |
| Evidence | Fallback **REPORTED**/ok als Fallback-Test; **nicht** als vollständige Series-Verifikation |

### C2 Supplemental (gleiche C:-Gate-DB)

| Field | Value |
|---|---|
| Project | **9 / Dental_Context_Search** |
| Series key | `02866_New_Luce_Church_of_Scotland,_New_Luce_` |
| Typ | reale `filename-series` (≥2 Medien) |
| GroupCard / Drilldown / Pagination | ausgeübt |
| Fokus-Series-Relation | soweit vorhanden |
| SQL↔API/UI | gegengeprüft |
| Evidence | **VERIFIED** (kein künstliches Seed) |

## Workflow D — Range Review

| Field | Value |
|---|---|
| Range (API) | ≥100 mit Keep-Schutz + Undo + Restore |
| Range (Browser) | virtualisierte Gallery, Shift-Range, **R**, Ergebnis sinkt, **Ctrl+Z**, Ergebnis restauriert |
| DB vor Mutation | Status der berührten IDs gesichert |
| Cleanup | finally-Restore + SQL-Verify; Cleanup-Fehler ⇒ Acceptance FAIL |
| Physische Finalization | keine |
| Evidence | **VERIFIED** |

## Workflow E — Fokusbeziehung

| Field | Value |
|---|---|
| Doppelklick → Fokus | VERIFIED (Browser) |
| P0-Relation klickbar | VERIFIED |
| Fokus-X / Escape | VERIFIED |
| Similar | disabled (P1) |
| Evidence | **VERIFIED** |

## Browser / Playwright

| Item | Status |
|---|---|
| Stack | Browser → static `dist` + buffered `/api` proxy → Review API → **writable** C:-Gate-DB |
| `REVIEW_DB_READONLY` | **0** (nötig für Range/Undo) |
| Category counts | **Produktions-Default** (set-basiert); **kein** `REVIEW_CATEGORY_LIVE_COUNTS` Bypass |
| Produktiv- / E:-Guard | aktiv; nur `C:\Temp\FindSeries-Review-Test\…` |
| Workflows A–E | **PASS** |
| Teardown | API/Web-Ports frei, `.run-state.json` entfernt, Review-Status restore |

Orchestrator-Default: Browser **an** (`-SkipBrowser` nur Diagnose).

## Category counts — P0 N+1 Fix (FIX REVIEW 2)

| Item | Vorher | Nachher |
|---|---|---|
| Root-Kategorien (P7) | **1385** | 1385 |
| Default live counts | N+1: `buildFilteredMediaCte` + `COUNT(*)` **pro Knoten** | **eine** set-basierte Query (fm + CATEGORY_GRAPH resolved + root/subtree map) |
| Einzel-Subtree-Stichprobe | ≈450–570 ms / Root | — |
| Extrapoliert Root-Load N+1 | ≈11+ Min (Event-Loop-Stall) | — |
| Root-List mit Filter (gemessen) | Bypass-only / praktisch unbenutzbar | **≈5.2 s** (C:-Gate, readonly measure) |
| Expand Kinder von 14367 (33) | **≈34.5 s** (N+1) | **≈0.24 s** |
| Kat. 14367 `mediaCount` | — | **1621** (= Gallery-Subtree) VERIFIED |
| Acceptance-Bypass | `REVIEW_CATEGORY_LIVE_COUNTS=0` | **entfernt** |

Regression: `review/api/tests/category-counts-setbased.test.ts` (>500 Nodes, Count-Korrektheit, Prepare-Budget).

## Performance (Cold/Warm, API)

Datei: `docs/review-mvp/bench/frv46-performance.csv`

Methodik: fresh SQLite-Connection cold-ish + warm (FRV-40-Klasse; **nicht** OS-disk-cold). Abweichungen vs FRV-40 sind **dokumentiert**, nicht als methodisch identische Regression behauptet.

| Metric | Beobachtung |
|---|---|
| `groups_provenance` | >20 % langsamer vs FRV-40 Cold p50 |
| `status_counts` | deutlich langsamer vs FRV-40 |
| Übrige | ≈ / besser |

Keine Optimierung in FRV-46. DoD erlaubt dokumentierte Perf-Abweichungen.

## Explorer-Baseline

**NOT_VERIFIED** — blockiert Done.

### Manuelle Anleitung (≤2–3 Minuten)

1. Review-Web mit derselben Gate-DB starten (Cat_Dentistry).
2. Kategorie **14367** (`Smiling men in the United States`) wählen; time-to-first-grid notieren.
3. Im **bisherigen Explorer** dieselbe reale Kategorie öffnen; time-to-first-grid notieren.
4. Eine vergleichbare Aktion (z. B. Gruppen-/Listenwechsel oder einfache Review-Aktion) in beiden UIs stoppen.
5. Werte hier eintragen:

| Metric | Review Web | Explorer | Notiz |
|---|---:|---:|---|
| time-to-first-grid (ms) | _todo_ | _todo_ | |
| vergleichbare Aktion (ms) | _todo_ | _todo_ | |

## Nutzen / Durchsatz

| Workflow | Medien / Schritt | Reload? | Undo |
|---|---|---|---|
| A Kategorie | ~1621 | nein | n/a |
| B Provenienz | 184991 | nein | n/a |
| C Fallback + Supplemental | 184991 + named series (P9) | nein | n/a |
| D Range | ≥2 UI / ≥100 API | nein | ja |
| E Fokus | Relation | nein | Fokus-X |

**Verdict:** PASS WITH DEVIATION — reversible Review-Semantik, Browser A–E, named-series supplemental VERIFIED; Abweichungen: zweiter Provenienztyp NOT_AVAILABLE, Cat_Dentistry named-series DATA_GAP (durch Supplemental ausgeglichen), Perf-Deltas vs FRV-40, Explorer-Baseline fehlt → Status bleibt **Testing**.

## Cleanup

- Review-Teststatusreste: nach Lauf keine (SQL-Verify)
- E:-Archiv unverändert
- C:-Gate-Kopie behalten bis externes Review
- Keine Produktiv-DB-Berührung

## Gate / E2E / CI

Lokal: `npm run test:gate`, `npm run test:e2e`, `npm run test:frv46` (ohne Skip).  
GitHub CI: Gate + E2E (ohne Real-DB).
