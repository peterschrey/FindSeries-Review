# Herkunft, Discovery und Gruppen – Semantik (FRV-3)

**Status:** Done (FRV-3)  
**Bezug:** `MVP_SPEC.md` §§11, 17–18 · reale Tabelle `discoveries` (read-only)

## Grundsatz

Provenienz ist **many-to-many**: ein Medium kann mehrere Discovery-Pfade haben.  
Herkunft ist gleichzeitig Metadatum, Chip, Filter, Gruppierung und Fokusbezug.  
**Keine erfundenen Typen** – nur belegte `discoveries.source_type` bzw. klar abgeleitete Facetten.

## UI-Taxonomie (Anzeige-Chips / Facetten)

Die UX-Begriffe aus der Spec werden auf reale `source_type`-Werte gemappt:

| UI-Chip / Facette | Belegte `source_type` | Anmerkung |
|---|---|---|
| **Category Search** | `category` | `source_value` = z. B. `Category:Dentistry`; oft `origin_category_id` |
| **Keyword Search** | `keyword`, `keyword-group`, `keyword-title`, `keyword-group-description`, `keyword-group-filename`, `depicts-search` | Detail im Tooltip/`source_value`/`query_text` |
| **Neighbor Search** | `neighbor`, `time-neighbour`, `uploader-neighbour` | `parent_media_id` bzw. Uploader/Zeitfenster in `source_value` |
| **Serie** (Gruppe/Sort) | `time-series`, `filename-series`, `filename` + Medienfelder | Kein eigener Chip „Serie“ als Discovery-Herkunftspflicht; Gruppierungsmodus |
| **Uploader** (Gruppe) | `media.current_uploader` / `original_uploader` + `uploader-neighbour` | Uploader ist primär Medienattribut |
| **Seed** (Gruppe/Filter) | *kein* gleichnamiger `source_type` | Neighbor: `media:<parent_media_id>`; Keyword: normalisierte `query_text`; sonst NULL |

Chip-Farben (Vorschlag, konsistent in UI): Category=blau, Keyword=violett, Neighbor=orange, Uploader=teal, Seed=grau (sobald ableitbar).

## Mehrfachzuordnung

- Filter **OR innerhalb** einer Facettenfamilie, **AND zwischen** aktivierten Facettenfamilien (Default; FRV-18 kann verfeinern).
- Galerie-Menge ist immer **dedupliziert nach `media_id`**.
- Gruppenaggregation nach Herkunft darf ein Medium in mehreren Herkunftsgruppen zählen; Drilldown zeigt die deduplizierte Teilmenge.

## Filter-Semantik

| Aktion | Wirkung |
|---|---|
| Chip/Facette „Category Search“ | Medien mit ≥1 Discovery `source_type='category'` |
| Unterwert (z. B. Category:Dental chairs) | `source_value` / Kategorieknoten |
| Mehrere Herkünfte aktiv | Schnittmenge der Familien (AND), sofern nicht anders gewählt |
| Facette entfernen | nur diese Einschränkung weg; übrige Filter bleiben |

## Gruppierung (P0)

| Modus | Gruppenschlüssel | Label |
|---|---|---|
| Herkunft | UI-Familie (s. Mapping) | z. B. „Category Search“ |
| Kategorie | `origin_category_id` / category title | Kategorietitel |
| Serie | abzuleitende `series_key` (FRV-8) | Serienlabel |
| Uploader | normalisierter Uploader | Uploadername |
| Seed | abzuleitender Seed-Schlüssel (siehe Lücke) | Seed/Query |

## Belegte Bestände (Produktiv, read-only)

Workspace-weit u. a.: `keyword`, `keyword-group`, `category`, `time-neighbour`, `keyword-title`, `filename`, `keyword-group-description`, `neighbor`, `time-series`, `uploader-neighbour`, `depicts-search`, `keyword-group-filename`, `filename-series`.

Projekt-Hinweis:

- `Cat_Dentistry` (id 7): praktisch nur `category`
- Keyword-/Context-Projekte (9, 14, 16): gemischte Typen inkl. Mehrfachherkunft

## Datenlücke: „Seed Search“

In `discoveries` existiert **kein** `source_type='seed'`. Verbindliche Ableitung:

1. Neighbor-Familie + `parent_media_id` → `seed_kind=media`, `seed_key=media:<id>`
2. Keyword-Familie + belastbares `query_text` → `seed_kind=query`
3. sonst kein Seed (nicht erfinden)

Details: `PROVENANCE_MODEL.md`.

## Verifikation – 10 Beispielmedien (Projekt 9, read-only)

Manuell gegen DB geprüft (Auszug):

| media_id | Titel (kurz) | Discovery-Pfade |
|---|---|---|
| 25 | tooth-drawer … V0012008 | keyword-group-description + time-neighbour |
| 33 | dentist Uncle Sam … V0011644 | keyword-group-description + time-neighbour |
| 34 | dentist gas … V0012121 | keyword-group-description + keyword-group-filename |
| 35 | dentist gas … V0011508 | keyword-group-description + keyword-group-filename + time-neighbour |
| 36 | dentist old patient … V0011542 | keyword-group-description + keyword-group-filename + time-neighbour |
| 37 | dentist restrained … V0011523 | keyword-group-description + time-neighbour |
| 38 | dentist new patient … V0011511 | keyword-group-description + keyword-group-filename + time-neighbour |
| 39 | dentist joke … V0011426 | keyword-group-description + keyword-group-filename + time-neighbour |
| 3 (Projekt 7) | (category-only) | category × mehrere `Category:*` |
| 8 (Projekt 7) | (category-only) | category × Dental clinics/offices/… |

Ergebnis: Mehrfachherkunft ist real; Cat_Dentistry-only-Projekte haben oft nur Category – UI muss damit umgehen.

## Begriffe

| Begriff | Bedeutung |
|---|---|
| Herkunftsfamilie | UI-Chip-Gruppe (Category/Keyword/Neighbor/…) |
| Discovery-Zeile | eine Zeile in `discoveries` |
| Drilldown | zusätzliche Einschränkung der Ergebnismenge über Gruppe |
| Dedup | eindeutige `media_id` in Galerie/Counts der Ergebnismenge |
