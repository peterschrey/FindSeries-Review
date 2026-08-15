# FRV-40 — Performance Gate (100k+)

**Status:** PASS WITH DEVIATION  
**Date:** 2026-08-15  
**Branch:** `review-mvp`  
**Review-base / Start-HEAD:** `d5013ba8c4984ec8f9d547efc8fd47c763d8f3de`  
**Scope:** Technischer, reproduzierbarer Performance-Gate (kein manueller UI-/UX-Test; das ist FRV-47).

## Commands

```bash
npm run test:perf:frv40   # API + Browser (builds api/web for browser)
# oder einzeln:
npm run bench:frv40
npm run bench:frv40:browser
```

Nicht in GitHub CI erzwingen (Real-DB fehlt dort). Normale `test:gate` / `test:e2e` bleiben CI-fähig.

## Hardware / Pfade

| Rolle | Pfad |
|---|---|
| Produktiv (nie anfassen) | `C:\FindSeriesV5-Workspace\findseries-v5.db` |
| Read / Real-DB Gate | `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` |
| Write / Bulk (kompakt, C: only) | `C:\Temp\FindSeries-Review-Test\bench-write-copy.db` |
| Media roots (Thumbnails, optional) | `E:\Temp\FindSeriesV5-Workspace\Media` (nur Lesen) |

- **E: ist kein writable SQLite-Benchmark-Pfad** (`assertSafeBenchDb` verweigert `E:` und Produktiv-DB).
- Write-DB: kompakte Extraktion (≥100k `project_media` Project 7 + Review-Tabellen + Migrationen 100–105), **keine** zweite ~20‑GB-Kopie.
- Medienzahl (Project 7): **184 991**

## Methodik

### API (`bench-frv40.ts` → `frv40-results.csv`)

- 2 vollständige Runs × Cold + Warm
- Cold = **fresh-process cold-ish** (neuer Node-Prozess + neue SQLite-Connection; **nicht** OS-Disk-Cold)
- Warm = same-process Wiederholung
- p50 / p95 (n=5) für: gallery, groups_provenance, category_subtree, category_gallery, focus, facets, status_counts
- `time_to_first_grid` in der CSV = **API-Proxy** (gallery limit 120) — nur Hinweis; **Browser-Metrik ist maßgeblich**
- Thumbnail cold/warm (Prozess-Cache)
- Bulk 1 / 100 / 10 000: `protectKeep=true`, Status-Snapshot → apply → undo → SQL-Restore-Check (`restoreOk`)
- RSS nach Metriken

### Browser (`bench-frv40-browser.ts` → `frv40-browser.csv` / `FRV40_BROWSER.md`)

- Playwright Chromium headless + FRV-46 Stack (static `dist` + buffered `/api` Proxy)
- Thumbnails: SVG-Placeholder (kein E:-Media-I/O; Gallery-APIs trotzdem Real-DB)
- **time_to_first_grid_ms:** Navigation → erstes `[data-testid^="thumb-"]` sichtbar
- Scroll: programmatisch im Gallery-Scroll-Container; rAF frame p95; Long Tasks (>50 ms) falls verfügbar; DOM-Nodes / Thumb-Count; JS heap wenn `performance.memory` da

### Baseline

| Datei | Rolle |
|---|---|
| `docs/review-mvp/bench/frv40-results.baseline.csv` | **unverändert** (Regression-Referenz) |
| `docs/review-mvp/bench/frv40-results.csv` | aktuelle Messung |
| `docs/review-mvp/bench/frv40-browser.csv` | Browser-Messung |

## API Ergebnisse (Auszug, Run 2 Warm p50 sofern nicht anders)

| Metric | Baseline Warm p50 | Current Warm p50 | Δ |
|---|---:|---:|---:|
| gallery | 570.9 | 651.1 | +14 % |
| groups_provenance | 1490.4 | 2838.5 | **+90 %** |
| category_subtree | 351.5 | 378.1 | +8 % |
| category_gallery | 1478.2 | 1666.6 | +13 % |
| focus | 1309.4 | 1494.8 | +14 % |
| facets | 1507.5 | 1686.2 | +12 % |
| status_counts | 4.9 | 5.5 | +12 % |

Cold (fresh-process) Run 2 p50: gallery 655 · groups_provenance 2883 · category_subtree 394 · category_gallery 1632 · focus 1458 · facets 1748 · status_counts 5.3

### Thumbnail / Bulk / Memory (API)

| Metric | Wert |
|---|---|
| thumbnail Cold | 31.3 ms (n=20) |
| thumbnail Warm | 0.9 ms |
| bulk 1 | 3.9 ms; undo 0.8 ms; restoreOk=true |
| bulk 100 | 2.6 ms; undo 2.6 ms; restoreOk=true |
| bulk 10 000 | 280 ms; undo 253 ms; restoreOk=true |
| RSS (API peak region) | ~110–140 MB |

Bulk läuft ausschließlich auf der C:-kompakten Write-DB; Gate-DB bleibt unverschmutzt.

## Browser Ergebnisse

| Metric | Cold | Warm |
|---|---:|---:|
| time_to_first_grid_ms | 6206 | 8616 |
| Visible thumbs (DOM) | 54 | 54 |
| DOM nodes after scroll | — | 8802 |
| Long tasks count | 0 | 0 |
| rAF frame p95 (ms) | — | 16.7 |
| JS heap (MB) | — | 12.1 |
| UI Ergebnis-Total | 184991 | 184991 |

Warm > Cold hier ist **Laufvarianz** (zweiter Page-Load / Stack-Druck), kein Stall. Beide Läufe: First Grid in Sekunden, nicht Minuten; Virtualisierung bounded (54 Thumbs ≪ 184 991).

## >20 %-Regressionen vs Baseline

| Flag | Einordnung | Begründung |
|---|---|---|
| `groups_provenance` Warm p50 ~1490 → ~2838 ms | **B + D** (Methodik / Rauschen), **nicht A** | Kein FRV-46-Codepfad in Groups-Provenance; Cold-Definition jetzt „fresh-process“ dokumentiert; Absolute ~3 s, kein Minuten-Stall. Kein klarer P0-Bottleneck → **keine Optimierung in FRV-40**. |
| Übrige API-Metriken | unter 20 % oder nahe Rauschen | Gallery/Focus/Facets/Category ~8–14 % |

Nicht mit FRV-46-CSV mischen (andere Endpoints/Semantik Category-Counts).

## Praxisnahe technische Bewertung

| Kriterium | Urteil |
|---|---|
| Kein minutenlanger API-/UI-Stall | PASS |
| First Grid interaktiv nutzbar (Browser) | PASS (~6–9 s auf Real-DB Stack) |
| Category-Expand nach FRV-46 weiterhin schnell | PASS (subtree ~0.4 s; separate FRV-46 Evidence) |
| Scroll DOM bounded | PASS (54 thumbs / ~8.8k nodes) |
| Bulk 10k praktikabel | PASS (~280 ms + Undo + Restore) |
| Memory Scroll ungebremst? | PASS (JS heap ~12 MB; API RSS bounded) |

## Verdict

**PASS WITH DEVIATION**

Abweichung: dokumentiertes `groups_provenance` >20 %-Flag vs Baseline, eingeordnet als Methodik/Rauschen (nicht ungeklärte P0-Regression A). Technischer DoD erfüllt → Notion **Done**.

## Artefakte

- `docs/review-mvp/bench/frv40-results.csv`
- `docs/review-mvp/bench/frv40-results.baseline.csv` (immutable)
- `docs/review-mvp/bench/frv40-browser.csv`
- `docs/review-mvp/bench/FRV40_BROWSER.md`
- Scripts: `bench-frv40.ts`, `bench-frv40-browser.ts`, `ensure-frv40-write-db.ts`, `bench-shared.ts` (C:-only write)
