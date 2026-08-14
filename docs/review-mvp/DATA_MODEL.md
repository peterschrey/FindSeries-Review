# Review-MVP Datenmodell – kompakt (Phase 1 / FRV-5–10)

Source of Truth fachlich: `MVP_SPEC.md`. Technisch: bestehende FindSeries-SQLite + Migrationen 100–104.

## Review-Status

```text
project_media (bestehend)
    └── LEFT JOIN media_review_status (project_id, media_id)
            status ∈ {unreviewed, keep, reject, unsure}
            fehlende Zeile = unreviewed

media_review_history  – Audit je Änderung (old/new, batch_id, source/action)
media_review_batches  – Bulk-Metadaten + protect_keep Counts
```

## Provenienz

```text
discoveries (bestehend, many-to-many)
    └── review_provenance_type_map.source_type → family/chip_label

Familien: category | keyword | neighbor | series | (uploader via media.*) | seed(abgeleitet)
Seed: query_text oder parent_media_id – kein erfundener source_type
```

## Kategorien

```text
categories ← project_categories (parent_category_id, depth)  → projektlokaler Baum
Medien: discoveries.source_type='category' + origin_category_id
Unterbaum/Union: WITH RECURSIVE … COUNT(DISTINCT media_id)
Optional: project_category_closure (leer, rebuildbar)
```

## Serien

```text
Strategien: filename | uploader_time | discovery
Optional materialisiert: media_series_keys (series_key, sequence_no, is_primary)
Primärwahl: discovery-series > filename-Gruppe > uploader_time
```

## Similarity (P1, optional)

```text
media_embedding_models (model_id, dim)
media_embeddings (media_id, model_id, status, blob/path, source_sha1)
media_phash (media_id, phash, status, source_sha1)
```

## Migrationen

| Ver | Inhalt |
|---|---|
| 100 | Review-Status/Historie/Batches |
| 101 | Provenance-Map + Discovery-/Uploader-Indizes |
| 102 | Category-Parent-Index + Closure-Tabelle |
| 103 | media_series_keys |
| 104 | Embedding/pHash-Metadaten |

Runner: `review/db/Invoke-ReviewMigrations.ps1` (`-Backup`, idempotent, Count-Check).
