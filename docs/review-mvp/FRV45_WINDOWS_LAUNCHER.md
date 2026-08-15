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
```

Default-DB: `C:\Temp\FindSeries-Review-Test\review-dev-mini.db`  
Produktiv-DB (`C:\FindSeriesV5-Workspace\findseries-v5.db`) wird **abgelehnt**.

Hinweis: `Open-FindSeriesReview.ps1` bleibt der Explorer-Sync-Einstieg (bestehend) und ist **nicht** der Review-UI-Launcher.

## Verhalten

| Thema | Verhalten |
|---|---|
| Start | API + Web, Readiness, optional Browser |
| Double Start | abgelehnt, wenn Session-PIDs leben |
| Stale PID | PID-Datei ohne lebende Prozesse → bereinigen, Start fortsetzen |
| Portkonflikt | Start verweigert; nennt Port + PID/Prozess; **kein** Kill fremder Prozesse |
| Partial Failure | eigene Session via Stop bereinigen; keine Orphans |
| Stop | nur PID-Datei-Session (+ Child-Trees); keine Blind-Kills von `node.exe` |
| Optional `-CleanOrphans` | beendet nur Listener, deren CommandLine auf `review\api` / `review\web` dieses Repos zeigt |
| Logs | `C:\Temp\FindSeries-Review-Test\logs\` → `api-*.log`, `web-*.log`, `findseries-review.pid` |
| Packaging | `Prepare-FindSeriesReview.ps1` → `npm ci` + builds; Start bevorzugt API `dist` + `vite preview` |

`vite preview` ist für P0 akzeptabel (Proxy `/api` → 8787 in `vite.config.ts`).

## Tests

| Test | Wann |
|---|---|
| `scripts/Test-ReviewLauncherHelpers.ps1` | CI-tauglich, in `npm run test:gate` |
| `scripts/Invoke-Frv45LauncherSmoke.ps1` | **lokal Windows** (Process-Lifecycle) — nicht in CI |

Manuelle Abnahme (Notion): frische Sitzung → Start → Mini-Review → Stop → Neustart → Stop; Ports frei, keine Orphans.
