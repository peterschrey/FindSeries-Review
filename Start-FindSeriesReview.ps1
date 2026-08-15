<#
.SYNOPSIS
  Starts FindSeries Review MVP (API + Web) on Windows.

.DESCRIPTION
  Preflight checks (Node >= 20, required folders, DB path, Review schema v105),
  then starts backend and frontend with PID-file locking, logs, port checks,
  and optional browser open. Does NOT auto-migrate the database.
  Never uses the productive FindSeries DB as a silent default.

.PARAMETER DatabasePath
  SQLite DB path. Default: $env:REVIEW_DB_PATH or
  C:\Temp\FindSeries-Review-Test\review-dev-mini.db

.PARAMETER ApiPort
  Backend port (default 8787).

.PARAMETER WebPort
  Frontend Vite port (default 5173).

.PARAMETER SkipBrowser
  Do not open the browser.

.PARAMETER ProductionWeb
  Force vite preview (requires review/web/dist).

.PARAMETER DevWeb
  Force Vite dev server even if dist/ exists.

.PARAMETER NoApiBuild
  Prefer tsx src/index.ts even if review/api/dist/index.js exists.

.EXAMPLE
  .\Start-FindSeriesReview.ps1
  .\Start-FindSeriesReview.ps1 -DatabasePath 'C:\Temp\FindSeries-Review-Test\review-dev-mini.db'
  .\Start-FindSeriesReview.ps1 -SkipBrowser -DevWeb

.NOTES
  Stop with: .\Stop-FindSeriesReview.ps1
  One-time prepare: .\Prepare-FindSeriesReview.ps1
  Logs: C:\Temp\FindSeries-Review-Test\logs\ (fallback: .\logs)
#>
[CmdletBinding()]
param(
    [string]$DatabasePath,
    [int]$ApiPort = 8787,
    [int]$WebPort = 5173,
    [switch]$SkipBrowser,
    [switch]$ProductionWeb,
    [switch]$DevWeb,
    [switch]$NoApiBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
. (Join-Path $RepoRoot 'scripts\ReviewLauncherCommon.ps1')

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Assert-ReviewSchema105([string]$DbPath, [string]$SqlitePath) {
    if (-not (Test-Path -LiteralPath $SqlitePath)) {
        throw "sqlite3 not found at $SqlitePath (needed to verify review_schema_migrations)."
    }
    $hasTable = & $SqlitePath $DbPath "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='review_schema_migrations';"
    if (($hasTable | Select-Object -Last 1) -ne '1') {
        throw @"
Review schema missing: table review_schema_migrations not found in:
  $DbPath
Apply Review migrations 100-105 first with:
  review\db\Invoke-ReviewMigrations.ps1 -DatabasePath <writable-copy>
This launcher does NOT auto-migrate.
"@
    }
    $ver = & $SqlitePath $DbPath "SELECT COUNT(*) FROM review_schema_migrations WHERE version=105;"
    if (($ver | Select-Object -Last 1) -ne '1') {
        $applied = & $SqlitePath $DbPath "SELECT IFNULL(group_concat(version),'none') FROM (SELECT version FROM review_schema_migrations ORDER BY version);"
        throw @"
Review schema version 105 is required but missing in:
  $DbPath
Currently applied Review versions: $($applied -join ' ')
Apply migrations with:
  review\db\Invoke-ReviewMigrations.ps1 -DatabasePath <writable-copy>
This launcher does NOT auto-migrate.
"@
    }
}

function Invoke-SessionCleanup {
    param([string]$PidFilePath)
    if (Test-Path -LiteralPath (Join-Path $RepoRoot 'Stop-FindSeriesReview.ps1')) {
        & (Join-Path $RepoRoot 'Stop-FindSeriesReview.ps1') -PidFile $PidFilePath -ApiPort $ApiPort -WebPort $WebPort -CleanOrphans
    } else {
        [void](Clear-ReviewSessionFromPidFile -PidFile $PidFilePath)
        [void](Stop-ReviewOrphanListeners -RepoRoot $RepoRoot -ApiPort $ApiPort -WebPort $WebPort)
    }
}

# --- resolve paths ---
$logDir = Get-ReviewLogDir -RepoRoot $RepoRoot
$pidFile = Get-ReviewPidFilePath -RepoRoot $RepoRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$apiLog = Join-Path $logDir "api-$stamp.log"
$webLog = Join-Path $logDir "web-$stamp.log"

if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
    if ($env:REVIEW_DB_PATH) {
        $DatabasePath = $env:REVIEW_DB_PATH
    } else {
        $DatabasePath = 'C:\Temp\FindSeries-Review-Test\review-dev-mini.db'
    }
}
$DatabasePath = [System.IO.Path]::GetFullPath($DatabasePath)

$apiDir = Join-Path $RepoRoot 'review\api'
$webDir = Join-Path $RepoRoot 'review\web'
$sharedDir = Join-Path $RepoRoot 'review\shared'
$sqlitePath = Join-Path $RepoRoot 'Tools\sqlite3.exe'

Write-Info "FindSeries Review launcher"
Write-Info "  Repo: $RepoRoot"
Write-Info "  DB:   $DatabasePath"
Write-Info "  Logs: $logDir"
Write-Info "  API log: $apiLog"
Write-Info "  Web log: $webLog"
Write-Info "  PID file: $pidFile"

# --- production DB hard refuse (no silent write target) ---
if (Test-IsProductionDbPath -Path $DatabasePath) {
    Write-Fail @"
REFUSING productive FindSeries DB as Review write target:
  $DatabasePath
Use a Temp copy (default: review-dev-mini.db) or an explicit migrated work copy.
This launcher never auto-migrates and never opens production for Review writes.
"@
    exit 1
}

# --- double-start / stale PID ---
if (Test-Path -LiteralPath $pidFile) {
    $existing = Read-ReviewPidState -PidFile $pidFile
    $alive = @(Get-AliveSessionPids -State $existing)
    if ($alive.Count -gt 0) {
        Write-Fail "Already running (PIDs: $($alive -join ', ')). Stop first: .\Stop-FindSeriesReview.ps1"
        exit 1
    }
    Write-Info "Removing stale PID file (no living session processes)"
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# --- Node ---
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Fail "Node.js not found on PATH. Install Node.js >= 20, then run .\Prepare-FindSeriesReview.ps1"
    exit 1
}
$nodeMajor = [int](((& node -v) -replace '^v', '' -split '\.')[0])
if ($nodeMajor -lt 20) {
    Write-Fail "Node.js v$nodeMajor detected; need >= 20."
    exit 1
}
Write-Ok "Node major version: $nodeMajor"

# --- required files ---
foreach ($dir in @($apiDir, $webDir, $sharedDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Fail "Required directory missing: $dir"
        exit 1
    }
}
foreach ($pkg in @(
        (Join-Path $apiDir 'package.json'),
        (Join-Path $webDir 'package.json'),
        (Join-Path $sharedDir 'package.json')
    )) {
    if (-not (Test-Path -LiteralPath $pkg)) {
        Write-Fail "Missing $pkg"
        exit 1
    }
}
Write-Ok "Required review packages present"

# --- DB ---
if (-not (Test-Path -LiteralPath $DatabasePath)) {
    Write-Fail "Database file not found: $DatabasePath"
    Write-Fail "Set REVIEW_DB_PATH or pass -DatabasePath to a valid SQLite copy."
    exit 1
}
try {
    Assert-ReviewSchema105 -DbPath $DatabasePath -SqlitePath $sqlitePath
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
Write-Ok "Review schema version 105 present"

# --- ports (never kill foreign processes) ---
if (-not (Test-PortFree -Port $ApiPort)) {
    Write-Fail "API port $ApiPort is already in use by: $(Get-PortOccupantSummary -Port $ApiPort)"
    Write-Fail "Free the port manually or choose -ApiPort. This launcher will not kill foreign processes."
    exit 1
}
if (-not (Test-PortFree -Port $WebPort)) {
    Write-Fail "Web port $WebPort is already in use by: $(Get-PortOccupantSummary -Port $WebPort)"
    Write-Fail "Free the port manually or choose -WebPort. This launcher will not kill foreign processes."
    exit 1
}
Write-Ok "Ports $ApiPort / $WebPort free"

# --- start API ---
$env:REVIEW_DB_PATH = $DatabasePath
$env:REVIEW_API_PORT = [string]$ApiPort
$env:REVIEW_API_HOST = if ($env:REVIEW_API_HOST) { $env:REVIEW_API_HOST } else { '127.0.0.1' }

$apiDist = Join-Path $apiDir 'dist\index.js'
$useBuiltApi = (-not $NoApiBuild) -and (Test-Path -LiteralPath $apiDist)
if ($useBuiltApi) {
    $apiInner = "node `"$apiDist`""
    Write-Info "Starting API (built): dist/index.js"
} else {
    $tsx = Join-Path $apiDir 'node_modules\.bin\tsx.cmd'
    if (-not (Test-Path -LiteralPath $tsx)) {
        Write-Fail "tsx not found at $tsx - run .\Prepare-FindSeriesReview.ps1"
        exit 1
    }
    $apiSrc = Join-Path $apiDir 'src\index.ts'
    $apiInner = "& `"$tsx`" `"$apiSrc`""
    Write-Info "Starting API (tsx): src/index.ts"
}

$apiCommand = @"
Set-Location -LiteralPath '$apiDir'
`$env:REVIEW_DB_PATH='$DatabasePath'
`$env:REVIEW_API_PORT='$ApiPort'
`$env:REVIEW_API_HOST='$($env:REVIEW_API_HOST)'
$apiInner *>> '$apiLog'
"@

$apiProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $apiCommand
) -PassThru -WindowStyle Hidden

# --- start Web ---
$viteBin = Join-Path $webDir 'node_modules\.bin\vite.cmd'
if (-not (Test-Path -LiteralPath $viteBin)) {
    Stop-ProcessTree -RootPid $apiProc.Id -Label 'api-shell'
    [void](Stop-ReviewOrphanListeners -RepoRoot $RepoRoot -ApiPort $ApiPort -WebPort $WebPort)
    Write-Fail "vite not found at $viteBin - run .\Prepare-FindSeriesReview.ps1"
    exit 1
}

$webDist = Join-Path $webDir 'dist'
$usePreview = $false
if ($DevWeb) {
    $usePreview = $false
} elseif ($ProductionWeb) {
    $usePreview = $true
} elseif (Test-Path -LiteralPath $webDist) {
    $usePreview = $true
}

if ($usePreview) {
    if (-not (Test-Path -LiteralPath $webDist)) {
        Stop-ProcessTree -RootPid $apiProc.Id -Label 'api-shell'
        [void](Stop-ReviewOrphanListeners -RepoRoot $RepoRoot -ApiPort $ApiPort -WebPort $WebPort)
        Write-Fail "ProductionWeb/preview requested but review/web/dist missing. Run: .\Prepare-FindSeriesReview.ps1"
        exit 1
    }
    $webInner = "& `"$viteBin`" preview --host 127.0.0.1 --port $WebPort --strictPort"
    Write-Info "Starting Web (vite preview) on $WebPort"
} else {
    $webInner = "& `"$viteBin`" --host 127.0.0.1 --port $WebPort --strictPort"
    Write-Info "Starting Web (vite dev) on $WebPort"
}

$webCommand = @"
Set-Location -LiteralPath '$webDir'
`$env:REVIEW_API_PORT='$ApiPort'
`$env:REVIEW_API_HOST='$($env:REVIEW_API_HOST)'
$webInner *>> '$webLog'
"@

try {
    $webProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $webCommand
    ) -PassThru -WindowStyle Hidden
} catch {
    Stop-ProcessTree -RootPid $apiProc.Id -Label 'api-shell'
    [void](Stop-ReviewOrphanListeners -RepoRoot $RepoRoot -ApiPort $ApiPort -WebPort $WebPort)
    Write-Fail "Failed to start Web process: $($_.Exception.Message)"
    exit 1
}

# Wait briefly and discover child node PIDs
Start-Sleep -Seconds 2

$apiNodePids = @(Get-ChildNodePids -ParentPid $apiProc.Id)
$webNodePids = @(Get-ChildNodePids -ParentPid $webProc.Id)
$apiTrack = if ($apiNodePids.Count) { $apiNodePids[0] } else { $apiProc.Id }
$webTrack = if ($webNodePids.Count) { $webNodePids[0] } else { $webProc.Id }

$tracked = @()
foreach ($pair in @(
        @{ role = 'apiShell'; pid = $apiProc.Id },
        @{ role = 'webShell'; pid = $webProc.Id },
        @{ role = 'api'; pid = $apiTrack },
        @{ role = 'web'; pid = $webTrack }
    )) {
    $ident = Get-ProcessIdentity -ProcessId ([int]$pair.pid)
    if ($ident) {
        $ident['role'] = $pair.role
        $tracked += [pscustomobject]$ident
    }
}
foreach ($nPid in $apiNodePids) {
    if ($nPid -eq $apiTrack) { continue }
    $ident = Get-ProcessIdentity -ProcessId ([int]$nPid)
    if ($ident) {
        $ident['role'] = 'apiNode'
        $tracked += [pscustomobject]$ident
    }
}
foreach ($nPid in $webNodePids) {
    if ($nPid -eq $webTrack) { continue }
    $ident = Get-ProcessIdentity -ProcessId ([int]$nPid)
    if ($ident) {
        $ident['role'] = 'webNode'
        $tracked += [pscustomobject]$ident
    }
}

$pidPayload = [ordered]@{
    startedAt     = (Get-Date).ToUniversalTime().ToString('o')
    databasePath  = $DatabasePath
    apiPort       = $ApiPort
    webPort       = $WebPort
    apiShellPid   = $apiProc.Id
    webShellPid   = $webProc.Id
    apiPid        = $apiTrack
    webPid        = $webTrack
    apiNodePids   = @($apiNodePids)
    webNodePids   = @($webNodePids)
    tracked       = @($tracked)
    apiLog        = $apiLog
    webLog        = $webLog
    mode          = $(if ($usePreview) { 'production-preview' } else { 'dev' })
}
$pidPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pidFile -Encoding UTF8

# --- readiness: direct API + web root + web proxy /api ---
$deadline = (Get-Date).AddSeconds(45)
$apiReady = $false
$webReady = $false
$proxyReady = $false
while ((Get-Date) -lt $deadline) {
    if (-not $apiReady) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$ApiPort/api/projects" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $apiReady = $true }
        } catch { }
    }
    if (-not $webReady) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$WebPort/" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $webReady = $true }
        } catch { }
    }
    if (-not $proxyReady) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$WebPort/api/projects" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $proxyReady = $true }
        } catch { }
    }
    if ($apiReady -and $webReady -and $proxyReady) { break }
    Start-Sleep -Milliseconds 500
}

if (-not $apiReady -or -not $webReady -or -not $proxyReady) {
    if (-not $apiReady) { Write-Fail "API did not become ready on port $ApiPort. See log: $apiLog" }
    if (-not $webReady) { Write-Fail "Web did not become ready on port $WebPort. See log: $webLog" }
    if (-not $proxyReady) { Write-Fail "Web proxy /api/projects did not become ready (REVIEW_API_PORT=$ApiPort). See log: $webLog" }
    Write-Info "Cleaning up partial start..."
    Invoke-SessionCleanup -PidFilePath $pidFile
    [void](Stop-ReviewOrphanListeners -RepoRoot $RepoRoot -ApiPort $ApiPort -WebPort $WebPort)
    exit 1
}

Write-Ok "API ready: http://127.0.0.1:$ApiPort"
Write-Ok "Web ready: http://127.0.0.1:$WebPort"
Write-Ok "Web proxy ready: http://127.0.0.1:$WebPort/api/projects -> API $ApiPort"
Write-Ok "PID file: $pidFile"
Write-Ok "Logs: $apiLog | $webLog"

if (-not $SkipBrowser) {
    Start-Process "http://127.0.0.1:$WebPort/"
}

Write-Ok "Started. Stop with: .\Stop-FindSeriesReview.ps1"
