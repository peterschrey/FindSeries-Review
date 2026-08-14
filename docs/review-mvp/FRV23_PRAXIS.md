# FRV-23 Praxis-Test (500+ Bilder)

**Datum:** 2026-08-14  
**DB:** synthetische Kopie via `createSyntheticReviewDb` + 500 Praxis-Medien (nicht Produktiv-DB)  
**Skript:** `review/api/scripts/praxis-frv23.ts`

## Workflow

1. Gallery seek-laden bis ≥520 IDs  
2. Range Slice 10..510 (500 Medien) → Bulk `reject`  
3. Defaultfilter unreviewed+unsure → Ergebnismenge schrumpft  
4. Kleiner Keep-Batch  
5. Undo B dann Undo A (Mehrfach-Undo)  
6. Alle 500 wieder unreviewed

## Messung

| Metrik | Wert |
|---|---|
| geladene IDs | 600 |
| Range-Größe | 500 |
| Gallery 1. Page | ~3 ms |
| Bulk reject 500 | ~11 ms |
| Undo B+A | ~10 ms |
| restored A | 500 |
| still rejected | 0 |

## Subjektiv

- Range/Bulk auf SQLite-Test-DB subjektiv sofort.  
- Auto-Advance UI an `loadGeneration` gekoppelt (kein 350-ms-Timer).  
- Fokus/Selection getrennt; Doppelklick-Delay für Fokus-only.  
- Teure Groups/Facets laufen asynchron nach Mutation (nicht UI-blockierend).

## Notion

FRV-23 nach PASS wieder **Done**.
