# Provenienzmodell aus FindSeries-Daten (FRV-6)

**Bezug:** `PROVENANCE.md`, `discoveries` Ist-Schema

## Query-Quelle

Primär: `discoveries(project_id, media_id, source_type, source_value, query_text, origin_category_id, parent_media_id, score, created_at)`.

Zusätzlich:

| Facette | Quelle |
|---|---|
| Uploader | `media.current_uploader` / `original_uploader` |
| Kategorie-Knoten | `origin_category_id` → `categories` / `project_categories` |
| Seed (abgeleitet) | siehe Seed-Semantik unten – **kein** erfundener `source_type` |

## Normalisierte Familie

Hilfstabelle `review_provenance_type_map` (Migration 101) mappt bekannte `source_type` → `family`/`chip_label`.

Unbekannte Typen: Familie **`unknown`** – nicht raten.

## Seed-Semantik (verbindlich)

| Fall | Bedingung | seed_kind | seed_key |
|---|---|---|---|
| Neighbor-Familie | `family='neighbor'` und `parent_media_id` vorhanden | `media` | `media:<parent_media_id>` |
| Keyword/Search | `family='keyword'` (o.ä. Suchpfad) und belastbares `query_text` | `query` | normalisierte Query (`lower(trim(query_text))`) |
| sonst | nicht belastbar | — | **NULL** (Seed nicht anzeigen) |

**Nicht:** generisch zuerst `query_text`, dann `parent_media_id` über alle Familien.

SQL-Skizze:

```sql
CASE
  WHEN m.family = 'neighbor' AND d.parent_media_id IS NOT NULL
    THEN 'media:' || d.parent_media_id
  WHEN m.family = 'keyword' AND d.query_text IS NOT NULL AND trim(d.query_text) <> ''
    THEN lower(trim(d.query_text))
  ELSE NULL
END AS seed_key
```

## Indizes (Migration 101)

- `ix_discoveries_project_source_media`
- `ix_discoveries_project_origin_cat` (partial)
- `ix_discoveries_project_parent` (partial)
- `ix_media_current_uploader` (partial)

## Verifikation

- Synthetisch: `Test-Phase1ReviewModel.ps1`
- Real read-only: `Test-ProvenanceSample.ps1` (≥50 reale Medien)
