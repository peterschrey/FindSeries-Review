# Review-MVP – Scope, Ziele und Nicht-Ziele (FRV-1)

Status: verbindlich für alle folgenden Tasks.  
Bezug: Notion FRV-1, abgestimmtes UI-Zielbild auf der FindSeries-Seite.

## Ziel

Aus **100.000+** gefundenen Bildern sehr schnell große irrelevante Mengen aussortieren – ohne die bestehende FindSeries Download-/Discovery-/Metadata-Pipeline zu gefährden.

## P0 (Muss für belastbaren MVP)

| Bereich | Inhalt |
|---|---|
| Review-Status | Global pro Medium: **Unbewertet**, **Behalten**, **Löschen**, **Unsicher** |
| Schutz | Bei Massen-Reject ist **Behalten** standardmäßig geschützt |
| Löschsemantik | „Löschen“ = Status only; physisches Löschen nur Finalisierungsschritt |
| UI | Eine integrierte Single View (Toolbar, Statusübersicht, Gruppen-Shelf, Facetten, Galerie, Kontextspalte) |
| Auswahl | Klick / Ctrl / Shift; Hotkeys K/R/U/N |
| Gruppen | Herkunft, Kategorie, Serie, Uploader, Seed (horizontale Shelf) |
| Provenienz | Nur aus echten DB-Daten (`discoveries` u. a.) |
| Kategorie/Serie | Navigation und Gruppierung über bestehende Projekt-/Mediendaten |
| Fokus | Optional: Doppelklick setzt Fokus; X in Fokuskarte hebt auf; Beziehungskarten in derselben Shelf |
| Statistik | Counts + segmentierte Balken für Gesamtbestand, Ergebnismenge, Auswahl (+ pro Gruppe) |
| Persistenz | Review-Status und Historie in SQLite; Sitzungsfilter später (P1-Task FRV-26) |
| Performance-Grundlage | Cursor-/seek-Pagination, Virtualisierung, keine 100k-DOM-Liste |
| Tests/Release | Backup/Migration-Sicherheit, Kern-E2E, Windows-Start |

## P1 (nach P0-Kern bzw. Messung)

- Lokale visuelle Ähnlichkeit (Embeddings, Threshold-Slider)
- Near-Duplicates / pHash / visuelle Cluster
- Embedding-/ANN-Optimierung nur bei nachgewiesenem Bedarf
- Review-Sitzung/Filterzustand persistieren (FRV-26)
- Master-Dokumentation/Agent-Prompt (FRV-47)

## P2 / später

- ANN-Index nur falls Brute-Force zu langsam (FRV-41)
- Weitere Optimierungen nach Benchmark

## Explizite Nicht-Ziele

- Sofortiges physisches Löschen beim Markieren als „Löschen“
- Cloud-APIs für Embeddings/Similarity (ohne ausdrückliche Entscheidung)
- Vollwertiges DAM / Asset-Management
- Separate Betriebsmodi Explorer / Cluster / Kategorieansicht
- Unnötiges Refactoring der bestehenden PowerShell-Pipeline
- Erfinden von Herkunftstypen, die die DB nicht belegt
- Vollständiges Laden aller Medien in den Browser

## Scope-Zuordnung (Checkliste für spätere Features)

Jedes neue Feature muss einem Punkt oben zugeordnet werden können:

1. Passt zu P0 → in Phase/Task der bestehenden Liste umsetzen.
2. Passt zu P1 → erst nach P0 bzw. laut Abhängigkeiten.
3. Passt zu Nicht-Zielen → ablehnen oder neue Notion-Entscheidung.
4. Unklar → STOP und Entscheidung einholen.

## Abnahmereferenz (FRV-1 Verifikation)

Gegen UI-Prototypen und reale Cat_Dentistry-Workflows:

1. Kategorieast reviewen und Massen-Reject mit Behalten-Schutz
2. Nach Herkunft filtern/gruppieren
3. Serie/Range mit Hotkeys
4. Optionaler Fokus inkl. Beziehungskarten
5. Statusstatistik Gesamt / Ergebnis / Auswahl konsistent

Keine unklaren Muss-Funktionen außerhalb dieser Datei und der Notion-Tasks.
