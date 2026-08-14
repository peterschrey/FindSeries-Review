# Similarity-/Embedding-Metadaten (FRV-9, P1)

**Bezug:** `MVP_SPEC.md` §10 – **blockiert P0 nicht**

## Prinzip

- Keine Cloud-API
- Modellversion zwingend an jedem Vektor (`model_id`)
- Modellwechsel ⇒ keine Vermischung
- pHash mit Algorithmus/Version (`algorithm`), pending/error ohne Hash erlaubt
- `ready` verlangt fertigen Hash bzw. Embedding

## Tabellen (Migration 104)

### `media_embedding_models` / `media_embeddings`

PK `(media_id, model_id)`. CHECK: `status='ready'` ⇒ Embedding-BLOB oder Pfad gesetzt.

### `media_phash`

PK `(media_id, algorithm)`. `phash` nullable; CHECK: `ready` ⇒ phash nicht leer.

Default-Algorithmus: `ahash64-v1`.

## Verifikation

`Test-Phase1ReviewModel.ps1`: ≥100 distinct media embeddings für model-a, model-b isoliert, pending ohne Hash ok, ready ohne Hash fail.
