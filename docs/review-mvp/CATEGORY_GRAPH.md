# Kategoriegraph und Unterbaum-Abfragen (FRV-7)

**Bezug:** `project_categories`, `categories`, `discoveries`  
**P0-Semantik validiert:** 2026-08-14 (Real-DB-Kopie, Cat_Dentistry)

## Ist-Modell

- `categories(id, title, normalized_title)` – globale Kategorie  
  Real: `title`/`normalized_title` typischerweise lowercase (`Category:women smiling with teeth`).
- `project_categories(project_id, category_id, parent_category_id, depth, …)` PK `(project_id, category_id)`
- Medien ↔ Kategorie: `discoveries` mit `source_type='category'`
  - ideal: `origin_category_id`
  - Real Cat_Dentistry: **~62 %** der category-Zeilen ohne `origin_category_id`, aber mit `source_value` wie `Category:<Titel>`

## P0-Auflösungsregel (verbindlich für FRV-11)

1. **Wenn** `origin_category_id` gesetzt → diesen Knoten verwenden.  
2. **Sonst** deterministisch auflösen:
   - `lower(discoveries.source_value) = categories.normalized_title`
   - Kategorie muss in `project_categories` des aktuellen Projekts liegen
   - Match muss **eindeutig** sein (`COUNT(DISTINCT category_id)=1`)
3. Mehrdeutige oder nicht auflösbare `source_value` → **keine** erfundene Mitgliedschaft.  
4. Ergebnis immer `DISTINCT media_id` / `COUNT(DISTINCT media_id)`.

Core-`discoveries` werden **nicht** massenhaft umgeschrieben. On-the-fly-Fallback + Indizes reichen für P0.

### Real-Messung (Projekt 7, null-`origin_category_id`)

| Metrik | Wert |
|---|---|
| null origin rows | 133 917 |
| source_value leer | 0 |
| source_value vorhanden | 133 917 |
| eindeutig auf `categories` (normalized) | 133 488 |
| mehrdeutig | 0 |
| nicht auflösbar | 429 |
| davon zusätzlich in `project_categories` (Zeilen) | 40 486 |
| davon distinct media | 35 892 |

## Medien eines Knotens (mit Fallback)

```sql
SELECT DISTINCT d.media_id
FROM discoveries d
WHERE d.project_id = :project_id
  AND d.source_type = 'category'
  AND d.origin_category_id = :category_id

UNION

SELECT DISTINCT d.media_id
FROM discoveries d
JOIN categories c ON c.normalized_title = lower(d.source_value)
JOIN project_categories pc
  ON pc.project_id = :project_id AND pc.category_id = c.id
WHERE d.project_id = :project_id
  AND d.source_type = 'category'
  AND d.origin_category_id IS NULL
  AND d.source_value IS NOT NULL AND trim(d.source_value) <> ''
  AND c.id = :category_id
  AND (
    SELECT COUNT(*) FROM categories c2
    WHERE c2.normalized_title = lower(d.source_value)
  ) = 1;
```

## Unterbaum (rekursiv, origin + Fallback)

```sql
WITH RECURSIVE sub AS (
  SELECT category_id AS id, 0 AS rel_depth
  FROM project_categories
  WHERE project_id = :project_id AND category_id = :root_id
  UNION ALL
  SELECT pc.category_id, sub.rel_depth + 1
  FROM project_categories pc
  JOIN sub ON pc.parent_category_id = sub.id
  WHERE pc.project_id = :project_id
    AND sub.rel_depth < 32
),
resolved AS (
  SELECT DISTINCT d.media_id
  FROM discoveries d
  JOIN sub ON d.origin_category_id = sub.id
  WHERE d.project_id = :project_id AND d.source_type = 'category'
  UNION
  SELECT DISTINCT d.media_id
  FROM discoveries d
  JOIN categories c ON c.normalized_title = lower(d.source_value)
  JOIN sub ON sub.id = c.id
  JOIN project_categories pc
    ON pc.project_id = :project_id AND pc.category_id = c.id
  WHERE d.project_id = :project_id
    AND d.source_type = 'category'
    AND d.origin_category_id IS NULL
    AND d.source_value IS NOT NULL AND trim(d.source_value) <> ''
    AND (
      SELECT COUNT(*) FROM categories c2
      WHERE c2.normalized_title = lower(d.source_value)
    ) = 1
)
SELECT COUNT(*) FROM resolved;  -- = COUNT(DISTINCT media_id)
```

## Union mehrerer Kategorien / Äste

Wie Unterbaum, aber Startmenge `category_id IN (:cat_ids)` und `UNION` (nicht `UNION ALL`) in der Rekursion. Dedup über äußeres `DISTINCT`/`UNION`.

## Counts je Knoten

- Anzeige schnell: `project_categories.member_count` (kann veralten)
- Review-genau: obige `resolved`-Query

## Indizes (Migration 101/102)

- `ix_discoveries_project_origin_cat` (origin vorhanden)
- `ix_discoveries_project_category_source_value` (category + null origin + source_value)
- `ix_categories_normalized_title`
- `ix_categories_title`
- `ix_project_categories_parent`

## Robustheit

| Risiko | Behandlung |
|---|---|
| Tiefe Cycles | `rel_depth < 32` |
| Mehrfachkategorie je Medium | DISTINCT media_id |
| Fehlendes origin_category_id | P0-Fallback über normalized `source_value` + project membership |
| Title-Case vs lowercase | immer `lower(source_value)` ↔ `normalized_title` |
| Ambiguity | nur eindeutige Matches |

## Optionale Hilfsstruktur

`project_category_closure` bleibt rebuildbar und leer in P0. Keine befüllte Review-Hilfstabelle nötig, solange On-the-fly-Fallback + Indizes genügen (validiert).

## Verifikation

- `review/db/tests/Test-CategoryGraphReal.ps1`
- `review/db/tests/Test-CategoryFallbackReal.ps1`
