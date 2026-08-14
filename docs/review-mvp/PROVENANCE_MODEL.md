# Provenienzmodell aus FindSeries-Daten (FRV-6)

**Bezug:** `PROVENANCE.md`, `discoveries` Ist-Schema

## Query-Quelle

Primär: `discoveries(project_id, media_id, source_type, source_value, query_text, origin_category_id, parent_media_id, score, created_at)`.

Zusätzlich:

| Facette | Quelle |
|---|---|
| Uploader | `media.current_uploader` / `original_uploader` (kein Discovery-Zwang) |
| Kategorie-Knoten | `origin_category_id` → `categories` / `project_categories` |
| Seed (abgeleitet) | `query_text` (Keyword-Familien) bzw. `parent_media_id` (Neighbor-Seed) |

## Normalisierte Familie

Hilfstabelle `review_provenance_type_map` (Migration 101):

| source_type | family | chip_label |
|---|---|---|
| category | category | Category Search |
| keyword | keyword | Keyword Search |
| keyword-group | keyword | Keyword Search |
| keyword-title | keyword | Keyword Search |
| keyword-group-description | keyword | Keyword Search |
| keyword-group-filename | keyword | Keyword Search |
| depicts-search | keyword | Keyword Search |
| neighbor | neighbor | Neighbor Search |
| time-neighbour | neighbor | Neighbor Search |
| uploader-neighbour | neighbor | Neighbor Search |
| time-series | series | Serie |
| filename-series | series | Serie |
| filename | series | Serie |

Unbekannte künftige `source_type`: Familie `unknown` – **nicht raten**, in UI als „Unbekannt“ oder ausblenden.

## Seed-Ableitung (ohne erfundenen source_type)

```text
seed_key =
  CASE
    WHEN query_text NOT NULL AND trim(query_text)<>'' THEN lower(trim(query_text))
    WHEN parent_media_id NOT NULL THEN 'parent:' || parent_media_id
    ELSE NULL
  END
```

Wenn `seed_key` NULL → Seed-Facette für dieses Medium nicht anzeigen.

## Effektive Herkunft je Medium (Skizze)

```sql
SELECT DISTINCT d.media_id, m.family, m.chip_label
FROM discoveries d
JOIN review_provenance_type_map m ON m.source_type = d.source_type
WHERE d.project_id = :project_id;
```

Mehrfachherkunft = mehrere Familien pro `media_id`.

## Indizes (Migration 101)

- `ix_discoveries_project_source_media (project_id, source_type, media_id)`
- `ix_discoveries_project_origin_cat (project_id, origin_category_id, media_id)` WHERE origin_category_id IS NOT NULL
- `ix_discoveries_project_parent (project_id, parent_media_id, media_id)` WHERE parent_media_id IS NOT NULL
- `ix_media_current_uploader (current_uploader)` WHERE current_uploader IS NOT NULL AND current_uploader<>''

## Lücken

1. Kein natives `source_type='seed'` → Seed nur abgeleitet.
2. Cat_Dentistry-Projekte oft nur `category` → Keyword/Neighbor-Chips fehlen dort erwartbar.
3. `uploader-neighbour` ist Neighbor-Familie, nicht Uploader-Attribut.
4. Detail-Labels (`source_value`) können sehr kardinal sein – Gruppen nach Familie zuerst, Drilldown nach Value optional.

## Verifikation

≥50 Medien mit nachvollziehbarer Provenienz (Skript `Test-ProvenanceSample.ps1`).
