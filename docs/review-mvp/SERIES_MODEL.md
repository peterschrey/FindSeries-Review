# Serienidentität und Reihenfolge (FRV-8)

**Bezug:** `MVP_SPEC.md` §17, reale `discoveries` / `media`

## Ziel

Pro Medium (projektbezogen) ableitbar:

- `series_key` – stabile Gruppen-ID
- `sequence_no` – Sortierschlüssel (natürliche Reihenfolge)

Keine physische Serien-Kopie von Dateien.

## Drei P0-Strategien (Priorität)

### S1 – Dateiname / natürliche Nummerierung

- Basis: `media.title` (ohne `File:`), optional Dateiname aus `downloads.local_path`
- `series_key` = normalisierter Präfix ohne trailing number run  
  Beispiel: `IMG_001.jpg`, `IMG_002.jpg`, `IMG_010.jpg` → key `img_` / `img`, seq 1,2,10
- `sequence_no` = geparste Integer-Sequenz (letzte Zahlgruppe); sonst sekundär alphanumerisch
- Natürliche Ordnung: numerisch vergleichen, **nicht** lexikographisch (`1,2,10` nicht `1,10,2`)

### S2 – Uploader + Zeitfenster

- Basis: `media.current_uploader` (Fallback `original_uploader`) + `current_timestamp` / `original_timestamp`
- `series_key` = `uploader:{norm}|bucket:{yyyy-mm-ddTHH}` (Stunden-Bucket, konfigurierbar)
- `sequence_no` = Unix-Zeit oder ISO-Timestamp sortierbar
- Belegt u. a. durch Discovery `uploader-neighbour` / `time-neighbour` als Hinweis, nicht als einzige Quelle

### S3 – Discovery-Serien / Neighbor-Reihenfolge

- `filename-series`, `time-series`: `series_key` aus `source_value` oder normalisiertem `query_text` + Typpräfix  
  z. B. `disc:time-series:{source_value}`
- `sequence_no` = `discoveries.created_at` bzw. eingebettete Zeit in `source_value`/`query_text`
- `neighbor` / `parent_media_id`: optionale Kette Seed→Kinder; MVP nutzt primär S1/S2/S3-filename/time

## Konfliktregel

Ein Medium kann mehrere Keys erfüllen. **Anzeige-Primärserie** (MVP):

1. explizites `filename-series` / `time-series` Discovery, sonst
2. S1 wenn ≥2 Medien denselben Dateiname-Key teilen, sonst
3. S2 Uploader-Zeitfenster

UI-Gruppierung „Serie“ nutzt den Primärkey; alternative Keys bleiben für Fokus-Beziehungen querybar.

## Persistenz (optional, Migration 103)

Materialisierte Hilfstabelle (rebuildbar):

```sql
media_series_keys(
  project_id, media_id, strategy, series_key, sequence_no, is_primary
)
```

P0-Backend darf Keys auch on-the-fly berechnen; Tabelle beschleunigt Gruppenaggregation.

## Index-Ideen

- Nach Materialisierung: `(project_id, strategy, series_key, sequence_no)`
- Für S2 roh: Uploader-Index (Migration 101)

## Verifikation

≥10 reale Serien manuell; Sortierung 1,2,10.
