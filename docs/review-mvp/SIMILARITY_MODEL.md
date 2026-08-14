# Similarity- / Embedding-Metadaten (FRV-9, P1)

**Bezug:** `MVP_SPEC.md` §10 – **blockiert P0 nicht**

## Prinzip

- Keine Cloud-API
- Modellversion zwingend an jedem Vektor
- Modellwechsel ⇒ keine Vermischung: neuer `model_id`, alte Zeilen invalid oder separat
- P0-Review funktioniert ohne diese Tabellen (leeren Zustand tolerieren)

## Tabellen (Migration 104)

### `media_embedding_models`

| Spalte | Bedeutung |
|---|---|
| model_id | PK, z. B. `clip-vit-b32-local-v1` |
| dim | Vektordimension |
| created_at | |
| notes | |

### `media_embeddings`

| Spalte | Bedeutung |
|---|---|
| media_id | FK media |
| model_id | FK models |
| status | `pending`/`ready`/`error`/`stale` |
| embedding | BLOB (float32 little-endian) oder ausgelagerter Pfad |
| embedding_path | optional Dateipfad statt BLOB |
| error | |
| computed_at | |
| source_sha1 | Invalidation wenn Datei/sha1 wechselt |
| PRIMARY KEY (media_id, model_id) |

### `media_phash`

| Spalte | Bedeutung |
|---|---|
| media_id | PK |
| phash | TEXT/HEX |
| status | |
| computed_at | |
| source_sha1 | |

### Optional später

Vektorindex/ANN-Metadaten in eigener Version – erst nach Benchmark (FRV-41).

## Invalidation / Recompute

- `source_sha1` ≠ aktuelles `media.sha1` ⇒ `stale`
- Modell entfernt/ersetzt ⇒ Queries filtern strikt `model_id = :active`
- Batch-Job resumable über `status='pending'`

## Verifikation

Schema + 100 Dummy-Zeilen zweier Modelle; Query nach model_id mischt nicht.
