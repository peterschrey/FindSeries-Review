# Kategoriegraph und Unterbaum-Abfragen (FRV-7)

**Bezug:** `project_categories`, `categories`, `discoveries`

## Ist-Modell

- `categories(id, title, normalized_title)` – globale Kategorie
- `project_categories(project_id, category_id, parent_category_id, depth, member_count, file_count, child_count, …)` PK `(project_id, category_id)`
- Pro Projekt maximal **ein** Parent je Kategorieknoten → projektlokaler Baum/Forest (keine Multi-Parent-Zeilen beobachtet)
- Medien ↔ Kategorie: `discoveries` mit `source_type='category'` und idealerweise `origin_category_id`

Commons-Realität: fachlich Graph; in FindSeries-Persistenz je Projekt als Parent-Pointer gespeichert. UI darf Baum zeigen; Queries müssen Dedup respektieren.

## Medien eines Knotens (ohne Unterbaum)

```sql
SELECT DISTINCT d.media_id
FROM discoveries d
WHERE d.project_id = :project_id
  AND d.source_type = 'category'
  AND d.origin_category_id = :category_id;
```

Fallback wenn `origin_category_id` fehlt: Match über `source_value` / Category-Titel (langsamer; Index auf origin_category_id priorisieren).

## Unterbaum (rekursiv)

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
    AND sub.rel_depth < 32  -- Zyklus-/Tiefen-Schutz
)
SELECT DISTINCT d.media_id
FROM discoveries d
JOIN sub ON d.origin_category_id = sub.id
WHERE d.project_id = :project_id
  AND d.source_type = 'category';
```

## Union mehrerer Kategorien / Äste

```sql
-- :cat_ids = ausgewählte Wurzelknoten
WITH RECURSIVE sub AS (
  SELECT category_id AS id FROM project_categories
  WHERE project_id = :project_id AND category_id IN (:cat_ids)
  UNION
  SELECT pc.category_id
  FROM project_categories pc
  JOIN sub ON pc.parent_category_id = sub.id
  WHERE pc.project_id = :project_id
)
SELECT DISTINCT d.media_id
FROM discoveries d
JOIN sub ON d.origin_category_id = sub.id
WHERE d.project_id = :project_id AND d.source_type = 'category';
```

`DISTINCT` = Deduplication. Count = `COUNT(DISTINCT media_id)`.

## Counts je Knoten

- Anzeige schnell: `project_categories.member_count` / `file_count` / `child_count` (Pipeline- gepflegt; kann veralten)
- Review-genau: `COUNT(DISTINCT media_id)` über Unterbaum + optional Review-Status-Join

## Robustheit

| Risiko | Behandlung |
|---|---|
| Tiefe Cycles | `rel_depth < 32` + besuchte Menge in App-Layer falls nötig |
| Mehrfachkategorie je Medium | DISTINCT media_id |
| Fehlendes origin_category_id | dokumentierte Lücke; Mapping über source_value nachziehen (FRV-6/Backend) |

## Optionale Hilfsstruktur (Migration 102)

`project_category_closure(project_id, ancestor_id, descendant_id, depth)` – **rebuildbar**, nicht Source of Truth. P0 kann ohne Closure mit Recursive CTE starten; Closure nur wenn Messung es verlangt.

Index ergänzend:

- `ix_project_categories_parent (project_id, parent_category_id, category_id)`

## Verifikation

Dentistry-Baum Queries + Stichproben-Counts (Skript).
