# Review-MVP – Scope, Ziele und Nicht-Ziele (FRV-1)

**Status:** Done (FRV-1)  
**Bezug:** `MVP_SPEC.md` (fachliche/UX-Source of Truth) · Notion FRV-1

Dieses Dokument verdichtet Scope und Grenzen. Bei Widerspruch gilt **`MVP_SPEC.md`**.

## Ziel

Sehr große FindSeries-Bildbestände (100.000+ Medien) schnell und sicher sichten, gruppieren, filtern und in vier Review-Zustände überführen – ohne die bestehende Download-/Discovery-/Metadata-Pipeline zu gefährden.

Hauptfall: große zusammenhängende Mengen (Kategorieäste, Herkunftsgruppen, Serien, Uploader, Seeds/Neighbor, Ranges), nicht Einzelbildpflege.

## P0 (Muss für belastbaren MVP)

| Bereich | Inhalt |
|---|---|
| Review-Status | Pro Medium genau einer: **Unbewertet**, **Behalten**, **Löschen**, **Unsicher** (projektbezogen/global laut MVP_SPEC) |
| Default-Filter | Unbewertet + Unsicher sichtbar; Behalten + Löschen ausgeblendet (einzeln zuschaltbar) |
| Schutz | Bei Massen-Reject wird **Behalten** standardmäßig nicht überschrieben; Counts transparent |
| Löschsemantik | „Löschen“ = Status only; physisches Löschen nur Finalisierung mit Dry-Run/Log |
| UI | Eine integrierte Single View (Toolbar, Statusübersicht, Gruppen-Shelf, Facetten, Galerie, Kontextspalte) |
| Auswahl | Einfachklick / Ctrl / Shift; Hotkeys K/R/U/N; kein Fokus per Einfachklick |
| Gruppen | Herkunft, Kategorie, Serie, Uploader, Seed (horizontale Shelf) |
| Provenienz | Nur aus echten DB-Daten; Mehrfachherkunft möglich |
| Kategorie/Serie | Unterbaum/Union, deduplizierte Mengen; natürliche Serienfolge |
| Fokus | Optional: Doppelklick setzt Fokus; × in Fokuskarte hebt auf; kein Toolbar-Button |
| Fokus-Beziehungen | Ähnlich \| Serie \| Kategorie \| Seed \| Uploader \| Herkunft, danach normale Gruppen |
| Statistik | Gesamtbestand + Ergebnismenge + Auswahl + je Gruppenkarte |
| Undo | Batch-/Action-Historie; Session-Undo für Massenaktionen |
| Persistenz | Review-Status/Historie in SQLite; Sitzungsfilter = P1 (FRV-26) |
| Performance | Cursor/seek-Pagination, Virtualisierung, lokaler Thumbnail-Cache |
| Tests/Release | Backup/Migration-Sicherheit, Kern-E2E, Windows-Start |

## P1 (nach P0-Kern bzw. Messung)

- Lokale Similarity inkl. Slider in der Karte „Ähnlich“ (UI-Platzhalter schon in P0-Struktur)
- Embeddings, pHash/Near-Duplicates, visuelle Cluster
- ANN nur bei nachgewiesenem Bedarf
- Review-Sitzung/Filterzustand persistieren (FRV-26)
- Master-Dokumentation/Agent-Prompt (FRV-47)

## P2 / später

- ANN-Index (FRV-41) und weitere Optimierungen nach Benchmark

## Explizite Nicht-Ziele

- Sofortiges physisches Löschen beim Markieren als „Löschen“
- Cloud-KI-Pflicht / Cloud-Embeddings ohne Entscheidung
- Vollwertiges DAM, Bildbearbeitung, Benutzer-/Rechteverwaltung, Mobile-First
- Separate Betriebsmodi Explorer / Cluster / Kategorieansicht
- Unnötiges Refactoring der bestehenden PowerShell-Pipeline
- Erfinden von Herkunftstypen, die die DB nicht belegt
- Sortierung nach Dateigröße als Kernfeature
- Vollständiges Laden aller Medien in den Browser

## Scope-Zuordnung

Jedes neue Feature muss zuordenbar sein:

1. P0 → bestehende Phase/Task
2. P1 → nach P0 bzw. Abhängigkeiten
3. Nicht-Ziel → ablehnen oder Notion-Entscheidung
4. Unklar → STOP

## Abnahme (Workflows A–E aus MVP_SPEC)

1. **Kategorieast** – Unterbaum, Union, Bulk-Löschen mit Behalten-Schutz  
2. **Herkunft** – filtern/gruppieren, Gruppe reviewen  
3. **Serie** – natürliche Reihenfolge, Shift-Range, `R`  
4. **Optionaler Fokus** – Doppelklick / × / Beziehungen; globale Filter bleiben  
5. **Statistik** – Gesamt / Ergebnis / Auswahl / Gruppen vs. DB-Counts  

Keine unklaren Muss-Funktionen außerhalb von `MVP_SPEC.md` und den Notion-Tasks.
