# Review-Status und Schutzregeln (FRV-2)

**Status:** In Progress → Done nach Abnahme  
**Bezug:** `MVP_SPEC.md` §§3, 15–16, 23, 25 · Notion FRV-2

## Statusmodell

Jedes Medium hat im Review **genau einen projektbezogenen Status**:

> `media_review_status` = Reviewstatus **pro Projekt**, aber **global über alle Filter/Gruppen/Cluster dieses Projekts**.

Das ist **nicht** workspaceweit. Die workspaceweite harte Ausschlussliste bleibt `media_rejections` (Explorer-Pfad).

Ein normales Setzen von Reviewstatus `reject` erzeugt **keine** `media_rejections`-Zeile. Überführung erst im späteren Finalisierungstask.

| Code (intern) | Anzeige | Bedeutung |
|---|---|---|
| `unreviewed` | Unbewertet | Noch nie bzw. zurückgesetzt |
| `keep` | Behalten | Explizit behalten; geschützt |
| `reject` | Löschen | Für spätere Finalisierung vorgesehen |
| `unsure` | Unsicher | Offen halten, bleibt im Default-Filter |

**Sparse-Default:** keine Current-Zeile = `unreviewed` (keine Massen-Vorfüllung).

## Zeitformat (kanonisch für Review-Tabellen)

Alle Review-Timestamps als UTC RFC3339 mit Millisekunden:

```text
YYYY-MM-DDTHH:mm:ss.fffZ
```

Beispiel: `2026-08-14T12:00:00.000Z`

Backend-Writes sollen dieselbe Formatter-Funktion verwenden (nicht mischen mit lokalen/ variablen Fractional-Digit-Formaten). Vorhandenes `Get-FsUtcNowText` (ISO-8601 `o`) ist UTC-kompatibel; Review-API soll auf die feste `.fffZ`-Konvention normalisieren.

## Default-Filter in der UI

| Status | Default sichtbar |
|---|---|
| Unbewertet | ja |
| Unsicher | ja |
| Behalten | nein (zuschaltbar) |
| Löschen | nein (zuschaltbar) |

„Offene Review-Menge“ = Unbewertet ∪ Unsicher.

## Statusübergänge

Alle Übergänge sind erlaubt (Hotkeys K/R/U/N und Bulk):

```text
unreviewed ↔ keep ↔ reject ↔ unsure
         ↘         ↗
```

- `N` setzt zurück auf `unreviewed`.
- **API-Semantik (vormerken für Backend):** Hotkey N / Reset → History schreiben, danach **Current-Zeile löschen** (sparse), nicht dauerhaft Millionen `unreviewed`-Rows speichern.
- Schema darf `status='unreviewed'` weiterhin akzeptieren (Migration/Kompatibilität); normale API soll DELETE der Current-Zeile nutzen.
- Keine Bestätigungsdialoge pro Aktion.
- Jede Änderung schreibt Historie (alter Status, neuer Status, Zeit, Quelle/Aktion, batch_id).
- **Undo-Hinweis:** Undo eines alten Batch darf einen zwischenzeitlich geschützten Current-Status nicht überschreiben. Current `batch_id` ist maßgeblich.

## Schutz von Behalten bei Massenaktionen

Standardregel für Bulk-Reject (Auswahl, Range, Gruppe, Kategorie-Union):

1. Zielstatus `reject` (oder anderer Bulk-Zielstatus außer explizitem Override).
2. Medien mit Status `keep` werden **nicht** geändert.
3. UI zeigt vor/bei der Aktion:
   - Anzahl in der Zielmenge,
   - Anzahl tatsächlich änderbarer Medien,
   - Anzahl geschützter `keep`-Medien.
4. Explizites Überschreiben von `keep` nur über bewussten Override (nicht Default; eigener Task/UI später).

Bulk auf `unsure` / `unreviewed` / `keep` folgt derselben Transparenz; Schutz gilt speziell als Default für Überschreiben von `keep` bei Reject.

## Historisierung / Undo

Mindestens:

- `batch_id` / Action-ID
- `media_id` (+ `project_id`)
- `old_status`, `new_status`
- `changed_at`, `source`/`action`
- optional Session

Session-Undo nimmt ganze Batches in umgekehrter Reihenfolge zurück.

## Physisches Löschen

Außerhalb dieses Statusmodells. Finalisierung nur für `reject`, mit Dry-Run; `keep` und `unsure` ausgeschlossen (`MVP_SPEC` §23).

## Testmatrix (Verifikation FRV-2)

Mindestens 12 Übergänge:

1. unreviewed → keep  
2. unreviewed → reject  
3. unreviewed → unsure  
4. keep → unreviewed  
5. keep → unsure  
6. keep → reject (nur Einzelaktion / Override, nicht Default-Bulk)  
7. reject → keep  
8. reject → unreviewed  
9. reject → unsure  
10. unsure → keep  
11. unsure → reject  
12. unsure → unreviewed  

Massenaktionen:

- A: gemischte Menge mit keep → Bulk-Reject ändert keep nicht  
- B: nur unreviewed → alle werden reject  
- C: Undo stellt exakte Vorzustände wieder her  

Behalten darf durch Gruppen-Reject nicht versehentlich überschrieben werden.
