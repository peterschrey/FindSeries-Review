# FRV-45 — Windows Start/Stop und lokales Packaging

## Ziel

Pragmatisches lokales Windows-Packaging (P0): nach einmaligem Prepare nur noch Start/Stop.

## Workflow

```powershell
# Einmalig (Dependencies + Production Builds)
.\Prepare-FindSeriesReview.ps1

# Alltag
.\Start-FindSeriesReview.ps1
.\Stop-FindSeriesReview.ps1

# Optional non-default ports
.\Start-FindSeriesReview.ps1 -ApiPort 19001 -WebPort 19002
```

Default-DB: `C:\Temp\FindSeries-Review-Test\review-dev-mini.db`  
Produktiv-DB (`C:\FindSeriesV5-Workspace\findseries-v5.db`) wird **abgelehnt**.

Hinweis: `Open-FindSeriesReview.ps1` bleibt der Explorer-Sync-Einstieg (bestehend) und ist **nicht** der Review-UI-Launcher.

## Verhalten

| Thema | Verhalten |
|---|---|
| Start | API + Web, Readiness, optional Browser |
| API-Port | `-ApiPort` / `REVIEW_API_PORT`; Vite `server.proxy` + `preview.proxy` lesen denselben Env-Wert (Fallback 8787) |
| Readiness | direkt `http://127.0.0.1:<ApiPort>/api/projects` **und** Web-Root **und** `http://127.0.0.1:<WebPort>/api/projects` (Proxy) |
| Double Start | abgelehnt, wenn Session-PIDs **mit gespeicherter Prozessidentität** leben |
| Stale PID | ohne passende Identität → nicht killen; PID-Datei bereinigen |
| Portkonflikt | Start verweigert; nennt Port + PID/Prozess; **kein** Kill fremder Prozesse |
| Partial Failure | eigene Session via Stop bereinigen; keine Orphans |
| Stop | nur tracked Identities (+ Child-Trees); nie blind `node.exe` / Cursor |
| Optional `-CleanOrphans` | beendet nur Listener, deren CommandLine auf `review\api` / `review\web` dieses Repos zeigt |
| Logs | `C:\Temp\FindSeries-Review-Test\logs\` → `api-*.log`, `web-*.log`, `findseries-review.pid` |
| Packaging | `Prepare-FindSeriesReview.ps1` → `npm ci` + builds; Start bevorzugt API `dist` + `vite preview` |

PID-Datei speichert neben PIDs auch `tracked[]` mit `creationTimeUtc`, `processName`, optional `commandLine`. Stop/Double-Start matchen diese Identität (PID allein reicht nicht — Schutz vor Windows PID-Reuse).

## Tests

| Test | Wann |
|---|---|
| `scripts/Test-ReviewLauncherHelpers.ps1` | CI-tauglich: lokal in `npm run test:gate` **und** GitHub Actions Step |
| `scripts/Invoke-Frv45LauncherSmoke.ps1` | **lokal Windows** (Process-Lifecycle, non-default Ports, PID-Reuse) — nicht in CI |

Manuelle Abnahme (Notion): frische Sitzung → Start → Mini-Review → Stop → Neustart → Stop; Ports frei, keine Orphans.
