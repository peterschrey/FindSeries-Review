# FRV-43 — End-to-End Tests (zentrale Review-Workflows)

## Architektur

```
Playwright (Chromium)
  → Vite preview (Web)
    → /api Proxy (REVIEW_API_PORT)
      → Fastify Review-API
        → isolierte synthetische SQLite (Temp, pro Lauf)
```

- Keine Produktiv-/Mini-/Gate-DB
- Pro Lauf: `New-Phase1TestDatabase.ps1` + Migrationen 100–105 + FRV-43-Seeds
- Stack-Start/Stop in `review/web/e2e/global-setup.ts` / `global-teardown.ts`
- Freie Ports, Teardown killt API/Web-Prozesse und löscht Temp-DB

## Fixture-Seeds (deterministisch)

- Project 7 (`Cat_Dentistry`)
- Keep auf Media **#4** (Bulk-Protect)
- Series-Keys: `Dental_chair_series` (1–3), `Instrument_series` (5–6)
- Neighbor-Discoveries für Seed/Fokus
- Kategorie-Baum 100 → 101/102 → 103

Zwischen Tests: Review-Status wird auf Fixture-Seed zurückgesetzt (Isolation).

## Commands

```powershell
# einmalig / CI: Dependencies + Chromium
cd review/web
npm ci
npx playwright install chromium
npm run build

# Root
npm run test:e2e          # headless
npm run test:e2e:headed   # sichtbarer Chromium
```

## Journeys (>=12)

| ID | Journey |
|---|---|
| J1 | Start / Default View |
| J2 | Single Click Selection |
| J3 | Ctrl Multiselect / Toggle |
| J4 | Shift Range |
| J5 | Range Reject via Keyboard (R) |
| J6 | Undo via Keyboard (Ctrl+Z) |
| J7 | Keep via Keyboard (K) |
| J8 | Keep Protection in Bulk |
| J9 | Unsure + Reset (U/N, sparse) |
| J10 | Category Navigation |
| J11 | Group Drilldown (Series) |
| J12 | DoubleClick Focus + × |
| J13 | Esc Focus |
| J14 | Focus Relation (Series) + Similar P1 disabled |
| CHAIN | Notion: Kategorie → Gruppe → Range → Reject → Undo → Fokus → Relation → Fokus-X |

## CI

Eigener GitHub-Actions-Job `review-e2e` (Windows):

- Node 22, `npm ci`, build shared/api/web
- `npx playwright install chromium --with-deps` (bzw. Windows ohne Linux-deps)
- `npm run test:e2e` in `review/web`
- Keine Mini/Full/Prod-DB

Der schnelle Gate-Job bleibt ohne Browser-Download.

## Bewusst nicht getestet (P1)

- Similarity-Clustering / Slider-Logik (nur disabled/unavailable-State)
- Finalize physical delete
- Performance 100k+

## Artefakte

Lokal/CI: `e2e-results/`, `e2e-report/`, Screenshots bei Fail — **gitignore**, nicht committen.

## Lokal ausgeführt (FRV-43 Verifikation)

| Lauf | Ergebnis |
|---|---|
| `npm run test:gate` | PASS (nach Vitest-Exclude von `e2e/`) |
| `npm run test:e2e` | **15/15 PASS** (~19s, `E2E_SKIP_REBUILD=1`) |
| `npm run test:e2e:headed` (Subset J5/J6/J12/J13/CHAIN) | **PASS** (sichtbarer Chromium) |

Keyboard: K / R / U / N / Ctrl+Z / Esc — in J5–J9, J13, CHAIN.  
Doppelklick-Fokus: J12, J13, CHAIN.
