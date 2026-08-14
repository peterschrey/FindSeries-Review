# FindSeries Review MVP – Spezifikation

**Status:** verbindliche MVP-Spezifikation  
**Stand:** 2026-08-14  
**Projekt:** FindSeries  
**Zweck:** sehr schneller Review und das Ausdünnen sehr großer Bildbestände (100.000+ Medien)

---

## 1. Ziel

Der Review-MVP soll es ermöglichen, sehr große FindSeries-Bildbestände schnell und sicher zu sichten, zu gruppieren, zu filtern und in vier globale Review-Zustände zu überführen.

Der wichtigste Anwendungsfall ist **nicht** die Einzelbildbewertung, sondern das schnelle Bearbeiten großer zusammenhängender Mengen:

- ganze Kategorien bzw. Kategorie-Äste,
- Gruppen gleicher Herkunft,
- Serien,
- Uploader,
- Seeds / Neighbor-Ergebnisse,
- visuell ähnliche Bilder,
- längere zusammenhängende Bereiche in einer sortierten Galerie.

Der Nutzer soll große irrelevante Mengen mit möglichst wenigen Interaktionen markieren können, ohne bereits geprüfte relevante Bilder erneut anfassen zu müssen.

---

## 2. Nicht-Ziele des MVP

Der MVP ist **kein** vollständiges Digital-Asset-Management-System.

Nicht Teil des P0-MVP:

- komplexe Bildbearbeitung,
- Cloud-basierte KI-Pflicht,
- automatische semantische Benennung aller Cluster,
- vollautomatische endgültige Löschung,
- komplexe Benutzer-/Rechteverwaltung,
- Mobile-First-UI,
- unnötige Refactorings der bestehenden FindSeries-Pipeline.

Similarity, Embeddings, pHash und visuelle Cluster können als P1 ergänzt werden, dürfen die P0-Kernfunktion nicht blockieren.

---

## 3. Grundprinzip: ein globaler Review-Status pro Bild

Jedes Medium besitzt projektbezogen/global für den Review genau einen Status:

1. **Unbewertet**
2. **Behalten**
3. **Löschen**
4. **Unsicher**

Der Status ist unabhängig davon, über welche Ansicht, Kategorie, Gruppe oder Herkunft das Bild gerade gefunden wurde.

### 3.1 Standardverhalten

- Neue/noch nie geprüfte Bilder: `Unbewertet`
- Standardfilter in der Review-UI:
  - `Unbewertet = sichtbar`
  - `Unsicher = sichtbar`
  - `Behalten = ausgeblendet`
  - `Löschen = ausgeblendet`
- Der Nutzer kann alle vier Status jederzeit explizit ein-/ausblenden.

### 3.2 Schutz von „Behalten“

`Behalten` ist ein explizit geschützter Status.

Bei Bulk-Aktionen wie „diese gesamte Kategorie auf Löschen setzen“ werden bereits als `Behalten` markierte Medien **standardmäßig nicht überschrieben**.

Die UI soll bei Massenaktionen transparent machen:

- Anzahl ausgewählter Medien,
- Anzahl tatsächlich zu ändernder Medien,
- Anzahl geschützter `Behalten`-Medien.

### 3.3 Löschen ist zunächst nur Review-Status

`Löschen` bedeutet im Review-MVP zunächst:

> Dieses Bild ist für den späteren Finalisierungsschritt zur Entfernung vorgesehen.

Es wird **nicht unmittelbar physisch gelöscht**.

Physisches Löschen erfolgt in einem separaten, kontrollierten Finalisierungsschritt mit Dry-Run/Preview, Logging und Fehlerbehandlung.

---

## 4. Zentrales UI-Konzept: eine integrierte Single View

Es gibt **keine getrennten Betriebsarten** wie:

- Explorer,
- Cluster-Ansicht,
- Kategorieansicht.

Stattdessen manipulieren alle Annäherungspunkte dieselbe Ergebnismenge.

Die Oberfläche besteht aus:

1. Toolbar
2. Statusübersicht
3. horizontale Gruppenübersicht / Group Shelf
4. linke Facetten / Navigation
5. zentrale Thumbnail-Galerie
6. rechte Auswahl-/Kontextspalte

---

## 5. Toolbar

Die Toolbar enthält mindestens:

### 5.1 Suche

Volltext-/Metadatensuche über sinnvoll verfügbare Felder, z. B.:

- Dateiname,
- Titel,
- Beschreibung,
- Kategorie,
- Uploader,
- Seed,
- Keyword,
- Herkunft.

### 5.2 Review-Statusfilter

Vier direkt sichtbare Chips:

- Unbewertet
- Unsicher
- Behalten
- Löschen

Aktiver Status ist optisch eindeutig erkennbar.

### 5.3 Gruppierung

Mindestens:

- Herkunft
- Kategorie
- Serie
- Uploader
- Seed

P1:

- visuelle Ähnlichkeit / Cluster,
- Near-Duplicates.

### 5.4 Sortierung

Review-relevante Sortierungen:

- Fund-/Discovery-Reihenfolge
- Dateiname / natürliche Serienfolge
- Uploader
- Kategorie
- Serie
- visuelle Ähnlichkeit zum Fokusbild (nur wenn technisch verfügbar)

Dateigröße o. ä. ist kein primäres Review-Kriterium und gehört nicht in die Kernsortierung.

---

## 6. Statusübersicht / Fortschritt

Die UI zeigt dauerhaft drei parallele Statusstatistiken:

### 6.1 Gesamtbestand

Statusverteilung aller Medien des Projekts:

- Unbewertet
- Behalten
- Löschen
- Unsicher

### 6.2 Aktuelle Ergebnismenge

Statusverteilung nach Anwendung der aktuell aktiven Filter/Facetten/Gruppe/Fokusbeziehung.

### 6.3 Aktuelle Auswahl

Statusverteilung ausschließlich der aktuell selektierten Bilder.

### 6.4 Darstellung

Je Bereich:

- Gesamtzahl,
- absolute Counts je Status,
- Prozentwerte,
- segmentierter Statusbalken mit konsistenter Farbgebung.

Empfohlene Statusfarben:

- Unbewertet: Grau
- Behalten: Grün
- Löschen: Rot
- Unsicher: Gelb

### 6.5 Gruppenstatistik

Jede Gruppenkarte und – bei aktivem Fokus – jede Fokus-Beziehungskarte zeigt ebenfalls:

- Gesamtzahl der Gruppe,
- Counts je Review-Status,
- Mini-Statusbalken.

Damit ist bereits in der Gruppenübersicht sichtbar, ob eine Gruppe noch offen oder weitgehend erledigt ist.

---

## 7. Gruppenübersicht / Group Shelf

Die Gruppenansicht aus den früheren UI-Prototypen bleibt ein zentrales Element.

### 7.1 Normalzustand – kein Fokus aktiv

Die horizontale Shelf zeigt ausschließlich Gruppen der aktuellen Ergebnismenge.

Beispiel:

```text
[Category Search] [Seed Search] [Neighbor Search] [Uploader A] [Uploader B] ...
```

oder bei Gruppierung nach Kategorie:

```text
[Dental chairs] [Dental units] [Instruments] [Dentists] ...
```

### 7.2 Gruppenkarte

Eine Gruppenkarte zeigt idealerweise:

- Gruppenname,
- Bildanzahl,
- 4–6 repräsentative Thumbnails,
- Statuscounts,
- Mini-Statusbalken.

Ein Klick auf eine Gruppenkarte:

> setzt die Gruppe als zusätzlichen Drilldown und zeigt deren Medien in der zentralen Galerie.

Die globalen Filter bleiben bestehen.

### 7.3 Mehrere Gruppen / Zurücksetzen

Der aktive Drilldown ist sichtbar und kann wieder entfernt werden, ohne die übrigen Filter zu verlieren.

---

## 8. Optionale Fokusfunktion

Der Fokus ist **nicht permanent aktiv** und darf die normale Gruppenansicht nicht dominieren.

### 8.1 Auswahl und Fokus sind getrennte Konzepte

- Einfachklick = Auswahl
- Ctrl+Klick = Mehrfachauswahl
- Shift+Klick = Bereichsauswahl
- **Doppelklick = Fokusbild setzen**

Ein einfacher Klick setzt **keinen Fokus**.

### 8.2 Fokus setzen

Per Doppelklick wird ein Bild zum Fokusbild.

Dann erscheint es als **erste Karte** in der bestehenden horizontalen Gruppen-Shelf.

Die Fokuskarte ist also kein separater UI-Bereich, sondern Teil derselben Gruppenübersicht.

### 8.3 Fokus aufheben

Die Fokuskarte besitzt oben rechts ein kleines:

`×`

Damit wird der Fokus aufgehoben.

**Kein separater großer „Fokus aufheben“-Button in der Toolbar.**

Optional darf `Esc` ebenfalls den Fokus aufheben.

### 8.4 Verhalten nach Aufheben

Beim Aufheben des Fokus:

- Fokusbild wird entfernt,
- aktive Fokusbeziehung wird entfernt,
- globale Statusfilter bleiben,
- Suchfilter bleiben,
- globale Herkunfts-/Kategorie-Facetten bleiben,
- normale Gruppenansicht bleibt bestehen.

---

## 9. Fokus-Beziehungen

Bei aktivem Fokus erscheinen **direkt hinter der Fokuskarte** zusätzliche Beziehungskarten:

1. Ähnlich
2. Serie
3. Kategorie
4. Seed
5. Uploader
6. Herkunft

Danach folgen wieder die normalen Gruppen der aktuellen Ergebnismenge.

Visuelles Prinzip:

```text
[FOKUSBILD] [ÄHNLICH] [SERIE] [KATEGORIE] [SEED] [UPLOADER] [HERKUNFT] | [normale Gruppe 1] [normale Gruppe 2] ...
```

### 9.1 Beziehungskarte

Jede Fokus-Beziehungskarte zeigt:

- Beziehungsname,
- konkrete Beziehung,
- Trefferzahl,
- Review-Statuscounts,
- Mini-Statusbalken.

Klick auf Beziehungskarte:

> Explorer/Galerie zeigt die abhängige Teilmenge.

---

## 10. Ähnlichkeit / Similarity

Similarity ist P1, aber die UI-Struktur ist bereits im MVP vorzubereiten.

### 10.1 Similarity-Slider

Die Beziehungskarte `Ähnlich` enthält direkt einen sichtbaren Slider.

Beispiel:

```text
Ähnliche Bilder
842 Bilder

[---------●-------]  86 %
```

Das Verschieben des Reglers aktualisiert:

- Threshold,
- Trefferzahl,
- Statusstatistik der Karte,
- bei aktiver Similarity-Beziehung die Galerie.

Updates müssen debounced sein, damit keine Request-Flut entsteht.

### 10.2 Technische Leitlinie

Keine Cloud-API voraussetzen.

Vorgehen:

1. lokales Embedding-Modell evaluieren,
2. Embeddings einmalig/resumable berechnen,
3. brute-force/lokale Suche benchmarken,
4. ANN-Index nur bei nachgewiesenem Bedarf.

Zusätzlich P1:

- pHash / Near-Duplicates,
- visuelle Cluster aus Embeddings,
- keine Pflicht zur automatischen Benennung der Cluster.

---

## 11. Herkunft / Provenienz

Die Herkunft eines Bildes ist eine zentrale Navigationsdimension.

Soweit durch reale FindSeries-Daten belegbar, unterscheiden:

- Category Search
- Keyword Search
- Seed Search
- Neighbor Search
- Uploader / Serie

Ein Bild kann mehrere Herkünfte besitzen.

Beispiel:

```text
Category Search + Neighbor Search
```

### 11.1 Herkunft ist gleichzeitig

- Metadatum,
- sichtbarer Chip am Thumbnail,
- Filter,
- Gruppierung,
- möglicher Fokusbezug.

### 11.2 Keine erfundene Provenienz

Die Implementierung muss zunächst das reale FindSeries-Datenmodell untersuchen.

Nur tatsächlich belegbare oder sauber ableitbare Discovery-Pfade dürfen angezeigt werden.

Fehlende Informationen sind als Datenlücke zu behandeln und nicht zu erfinden.

---

## 12. Kategorie-Navigation

Der Nutzer soll Kategorie-Strukturen als Annäherungspunkt verwenden können.

### 12.1 Anforderungen

- Parent/Child-Navigation,
- Lazy Expand,
- ganze Unterbäume,
- Ctrl-Mehrfachauswahl von Kategorien,
- Union mehrerer Kategorien,
- deduplizierte Medienmenge,
- Counts je Kategorie/Knoten.

### 12.2 Mehrfachzuordnung

Ein Medium kann in mehreren Kategorien liegen.

Deshalb bedeutet:

> Kategorie auswählen

nicht:

> Datei gehört exklusiv zu dieser Kategorie.

Kategorieaktionen arbeiten immer auf der resultierenden deduplizierten Medienmenge.

### 12.3 Kategorie-Bulk-Review

Beispiel:

```text
Dental chairs           2.311
Dental units            1.844
Treatment rooms           925

Union                   4.582 eindeutige Bilder
```

Diese Menge kann geöffnet und als Ganzes bzw. teilweise reviewed werden.

---

## 13. Explorer / Galerie

Die zentrale Galerie ist der eigentliche Arbeitsbereich.

### 13.1 Darstellung

- große, schnell scanbare Thumbnails,
- Review-Status dezent am Rand/Farbcode,
- Herkunftschips,
- optional Fokusmarkierung,
- minimale Zusatzinformationen.

### 13.2 Performance

Für 100.000+ Bilder:

- Virtualisierung,
- Lazy Loading,
- lokaler Thumbnail-Cache,
- niemals 100k DOM-Elemente gleichzeitig,
- Originaldateien nicht für jede Gridzelle vollständig dekodieren,
- stabile Pagination/Seek-Strategie.

---

## 14. Auswahl und Range-Workflow

Die Interaktion soll möglichst nah am effizienten Windows-Explorer-Workflow liegen.

### 14.1 Einfachauswahl

Einfachklick auf Bild:

- setzt Einzel-Auswahl,
- setzt **keinen Fokus**.

### 14.2 Mehrfachauswahl

Ctrl+Klick:

- Bild hinzufügen/entfernen.

### 14.3 Bereichsauswahl

Shift+Klick:

- markiert alle Bilder zwischen Auswahlanker und Zielbild in der aktuellen stabilen Sortierung.

Das muss logisch korrekt über virtualisierte Bereiche/mehrere Bildschirmseiten funktionieren.

### 14.4 Hauptworkflow für lange Serien

Beispiel:

1. erstes unpassendes Bild anklicken,
2. schnell nach unten scrollen,
3. erstes wieder passendes Bild finden,
4. Bild davor mit Shift markieren,
5. `R`,
6. kompletter Bereich wird auf `Löschen` gesetzt,
7. Review springt sinnvoll weiter.

---

## 15. Tastatursteuerung

Mindestens:

- `K` = Behalten
- `R` = Löschen
- `U` = Unsicher
- `N` = Unbewertet

Optional später:

- Begin/End-Range-Hotkeys,
- PageUp/PageDown für große Sprünge,
- `Esc` Fokus aufheben.

Keine Bestätigungsdialoge für jede Review-Aktion.

Sicherheit kommt durch:

- Undo,
- Statushistorie,
- getrennte physische Finalisierung.

---

## 16. Undo / Historie

Review-Massenaktionen müssen nachvollziehbar und reversibel sein.

Benötigt:

- Batch-ID / Action-ID,
- alter Status,
- neuer Status,
- Zeitpunkt,
- Quelle/Aktion,
- optional Session.

Mindestens die letzten Review-Aktionen einer Session müssen rückgängig gemacht werden können.

---

## 17. Serien

Serien sind ein zentraler Gruppierungs- und Sortiermechanismus.

Mögliche reale Quellen:

- natürliche Dateinamensfolge,
- Uploader + Aufnahme-/Upload-Zeitfenster,
- vorhandene Neighbor-/Discovery-Zusammenhänge,
- bestehende FindSeries-Serieninformationen.

Die Implementierung muss zunächst reale Daten untersuchen und dann stabile:

- `series_key`
- `sequence_no`

ableiten.

Natürliche Reihenfolge:

`1, 2, 3, 10`

nicht:

`1, 10, 2, 3`

---

## 18. Gruppenbildung – MVP und spätere Erweiterung

### P0 / sofort sinnvoll

- Herkunft,
- Kategorie,
- Serie,
- Uploader,
- Seed.

### P1

- Dateinamen-/Sequenzmuster,
- pHash/Near-Duplicates,
- Similarity zum Fokusbild,
- automatische visuelle Cluster.

Alle Gruppen sind nur **virtuelle Teilmengen derselben Medienbasis**.

Keine Dateien für Gruppen physisch kopieren.

---

## 19. Backend-/Datenbank-Leitlinien

Die bestehende FindSeries-SQLite ist die technische Realität.

### 19.1 Vor Implementierung

Tatsächliches Schema untersuchen:

- Projekte,
- Medien,
- Kategorien,
- Discovery,
- Downloads,
- Pfade,
- vorhandene Indizes,
- vorhandene Migrationen.

Keine Tabellennamen oder Beziehungen raten.

### 19.2 Review-Daten

Review-Status und Historie so modellieren, dass:

- globale Statusabfrage schnell ist,
- Bulk-Updates transaktional sind,
- Undo möglich ist,
- bestehende FindSeries-Daten nicht beschädigt werden.

### 19.3 Migration

- versioniert,
- idempotent,
- transaktional,
- zunächst nur auf DB-Kopie,
- `PRAGMA quick_check`,
- bei Bedarf `PRAGMA integrity_check`,
- zentrale Counts vor/nach Migration vergleichen.

---

## 20. API-/Query-Leitlinien

100.000+ Medien dürfen nicht komplett zum Browser übertragen werden.

Benötigt:

- stabile cursor/seek-basierte Pagination,
- Filterkombinationen,
- Gesamtcounts,
- Statuscounts,
- Gruppenaggregation,
- repräsentative Medien je Gruppe,
- Kategoriebaum/Lazy Loading,
- Bulk-Review,
- Fokusbeziehungen.

SQL:

- set-basiert,
- passende Indizes anhand realer Query-Pläne,
- `EXPLAIN QUERY PLAN`,
- keine unnötige Indexexplosion.

---

## 21. Thumbnail-Konzept

Die Grid-Ansicht benötigt kleine lokale Thumbnails.

Anforderungen:

- deterministischer Cachepfad,
- Lazy Generation,
- Cache-Hit schnell,
- Originals können auf externer SSD bleiben,
- Thumbnail-Cache bevorzugt auf schneller lokaler SSD,
- Fehlerplaceholder,
- begrenzte parallele Erzeugung.

---

## 22. Performance-Ziele

Der MVP ist nur erfolgreich, wenn sich 100.000+ Bilder flüssig bearbeiten lassen.

Zu messen:

- App-Start,
- erste Galerie,
- Filterwechsel,
- Gruppenaggregation,
- Kategorieexpand,
- Scrollen,
- Bulk-Review,
- Statusstatistik,
- Thumbnail-Cold/Warm-Cache.

Performance immer erst messen, dann optimieren.

Keine komplexe ANN-/Index-Architektur ohne nachgewiesenen Bedarf.

---

## 23. Finalisierung / physisches Löschen

Separater Prozess.

Vor physischem Löschen:

- Count,
- Dry-Run,
- betroffene Pfade,
- Statusprüfung,
- `Behalten`/`Unsicher` ausgeschlossen,
- Logging.

Fehlerfälle:

- Datei fehlt,
- Datei gesperrt,
- DB/FS-Diskrepanz.

Ziel: kein inkonsistenter Zustand.

---

## 24. UX-Rangfolge / Source of Truth

Bei Implementierungsfragen gilt folgende Rangfolge:

1. **Diese Datei `MVP_SPEC.md`** – fachliche und UX-Source-of-Truth.
2. **Notion `Review MVP – Tasks`** – Umsetzungsplan, Abhängigkeiten, DoD, Tests.
3. **Aktueller UI-Prototyp** – visuelle/interaktive Referenz.
4. **Bestehender FindSeries-Code und reale SQLite-Struktur** – technische Realität.

Wenn technische Realität und Spezifikation kollidieren:

- nicht stillschweigend raten,
- Unterschied dokumentieren,
- bei wesentlicher Architekturentscheidung stoppen und Rückfrage stellen.

---

## 25. Verbindliche UI-Entscheidungen aus der letzten Abstimmung

Diese Punkte sind final und ersetzen frühere Varianten:

- Eine integrierte Single View.
- Frühere horizontale Gruppenübersicht bleibt erhalten.
- Fokus ist optional.
- Einfachklick = Auswahl.
- Doppelklick = Fokus setzen.
- Fokusbild erscheint nur bei aktivem Fokus als erste Karte der Gruppenübersicht.
- Fokus kann über ein **kleines X direkt in der Fokuskarte** aufgehoben werden.
- **Kein** separater „Fokus aufheben“-Button in der Toolbar.
- Bei Fokus folgen Beziehungskarten: Ähnlich, Serie, Kategorie, Seed, Uploader, Herkunft.
- Danach folgen weiterhin die normalen Gruppen der aktuellen Ergebnismenge.
- Similarity-Slider sitzt direkt in der Beziehungskarte „Ähnlich“.
- Statusübersicht gleichzeitig für:
  - Gesamtbestand,
  - Ergebnismenge,
  - Auswahl.
- Jede Gruppe zeigt zusätzlich ihre eigene Statusstatistik.
- Sortierung nach Dateigröße o. ä. ist kein Kernfeature.
- `Behalten` muss über spätere Filter/Cluster hinweg erhalten bleiben und standardmäßig vor Massen-Reject geschützt sein.

---

## 26. MVP-Abnahmekriterien

Der P0-MVP ist abnahmefähig, wenn mindestens folgende reale Workflows mit einer Cat_Dentistry-DB-Kopie funktionieren:

### Workflow A – Kategorieast

1. Kategorie/Unterbaum wählen.
2. eindeutige Medienmenge anzeigen.
3. Statusverteilung sehen.
4. große Auswahl / Range auf `Löschen`.
5. bereits `Behalten` geschützte Bilder bleiben erhalten.

### Workflow B – Herkunft

1. `Category Search`, `Seed Search`, `Neighbor Search` o. ä. filtern/gruppieren.
2. schlechte Discovery-Gruppe öffnen.
3. repräsentative Bilder ansehen.
4. ganze Gruppe oder Teilmenge reviewen.

### Workflow C – Serie

1. Seriengruppe öffnen.
2. natürliche Reihenfolge.
3. erstes schlechtes und letztes schlechtes Bild per Shift markieren.
4. `R`.
5. nächste offene Position bleibt sinnvoll erreichbar.

### Workflow D – optionaler Fokus

1. Einfachklick wählt Bild – kein Fokus.
2. Doppelklick setzt Fokus.
3. Fokuskarte erscheint in Shelf.
4. Kategorie/Serie/Seed/Uploader/Herkunft-Beziehungen funktionieren.
5. kleines `X` in Fokuskarte entfernt Fokus.
6. globale Filter bleiben erhalten.

### Workflow E – Statistik

Nach Einzel- und Massenaktionen stimmen:

- Gesamtbestand,
- aktuelle Ergebnismenge,
- aktuelle Auswahl,
- Gruppenstatistiken

mit den DB-Counts überein.

---

## 27. Implementierungsprinzip

Nicht „den gesamten MVP auf einmal“ bauen.

Taskweise:

1. Task lesen.
2. Abhängigkeiten prüfen.
3. kleinste belastbare Implementierung.
4. Tests.
5. Definition of Done prüfen.
6. erst dann Task abschließen.
7. bei echter Architekturabweichung stoppen.

Ziel ist **schnell ein belastbarer P0-MVP**, nicht vorsorglich ein perfektes Komplettsystem.
