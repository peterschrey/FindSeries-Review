<#
.SYNOPSIS
  Starts FindSeries Review MVP (API + Web) on Windows.

.DESCRIPTION
  Preflight checks (Node >= 20, required folders, DB path, Review schema v105),
  then starts backend and frontend with PID-file locking, logs, port checks,
  and optional browser open. Does NOT auto-migrate the database.

.PARAMETER DatabasePath
  SQLite DB path. Default: $env:REVIEW_DB_PATH or
  C:\Temp\FindSeries-Review-Test\review-dev-mini.db
  (full gate / 100k+ copy only via explicit -DatabasePath / REVIEW_PERF_DB_PATH)

.PARAMETER ApiPort
  Backend port (default 8787 = REVIEW_API_PORT / review/api/src/index.ts).

.PARAMETER WebPort
  Frontend Vite port (default 5173 = review/web/vite.config.ts).

.PARAMETER SkipBrowser
  Do not open the browser.

.PARAMETER ProductionWeb
  Serve Vite production build via `vite preview` instead of `vite` dev server.
  Requires review/web/dist to exist (run npm run build in review/web first).

.PARAMETER NoApiBuild
  Prefer `tsx src/index.ts` even if review/api/dist/index.js exists.

.EXAMPLE
  .\Start-FindSeriesReview.ps1
  .\Start-FindSeriesReview.ps1 -DatabasePath 'E:\Temp\FindSeries-Review-Test\frv44-work.db'
  $env:REVIEW_DB_PATH = 'E:\...\copy.db'; .\Start-FindSeriesReview.ps1 -SkipBrowser

.NOTES
  Stop with: .\Stop-FindSeriesReview.ps1
  Logs: C:\Temp\FindSeries-Review-Test\logs\ (fallback: .\logs)
  PID file: same log dir / findseries-review.pid
  Required Review schema: version 105 in review_schema_migrations (no auto-migrate).
#>
[CmdletBinding()]
param(
    [string]$DatabasePath,
    [int]$ApiPort = 8787,
    [int]$WebPort = 5173,
    [switch]$SkipBrowser,
    [switch]$ProductionWeb,
    [switch]$NoApiBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Get-LogDir {
    $preferred = 'C:\Temp\FindSeries-Review-Test\logs'
    try {
        if (-not (Test-Path -LiteralPath $preferred)) {
            New-Item -ItemType Directory -Path $preferred -Force | Out-Null
        }
        return (Resolve-Path -LiteralPath $preferred).Path
    } catch {
        $fallback = Join-Path $RepoRoot 'logs'
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
        return (Resolve-Path -LiteralPath $fallback).Path
    }
}

function Test-PortFree([int]$Port) {
    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return -not $listeners
}

function Get-NodeMajorVersion {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { return $null }
    $v = (& node -v 2>$null) -replace '^v', ''
    if (-not $v) { return $null }
    return [int](($v -split '\.')[0])
}

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

# --- resolve paths ---
$logDir = Get-LogDir
$pidFile = Join-Path $logDir 'findseries-review.pid'
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

# --- double-start guard ---
if (Test-Path -LiteralPath $pidFile) {
    $existing = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($existing) {
        $alive = @()
        foreach ($p in @($existing.apiPid, $existing.webPid)) {
            if ($p -and (Get-Process -Id $p -ErrorAction SilentlyContinue)) { $alive += $p }
        }
        if ($alive.Count -gt 0) {
            Write-Fail "Already running (PIDs: $($alive -join ', ')). Stop first: .\Stop-FindSeriesReview.ps1"
            exit 1
        }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# --- Node ---
$nodeMajor = Get-NodeMajorVersion
if ($null -eq $nodeMajor) {
    Write-Fail "Node.js not found on PATH. Install Node.js >= 20."
    exit 1
}
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
if (-not (Test-Path -LiteralPath (Join-Path $apiDir 'package.json'))) {
    Write-Fail "Missing review/api/package.json"
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $webDir 'package.json'))) {
    Write-Fail "Missing review/web/package.json"
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $sharedDir 'package.json'))) {
    Write-Fail "Missing review/shared/package.json"
    exit 1
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

# --- ports ---
if (-not (Test-PortFree $ApiPort)) {
    Write-Fail "API port $ApiPort is already in use."
    exit 1
}
if (-not (Test-PortFree $WebPort)) {
    Write-Fail "Web port $WebPort is already in use."
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
    $apiCmd = "node `"$apiDist`""
    Write-Info "Starting API (built): $apiCmd"
} else {
    $tsx = Join-Path $apiDir 'node_modules\.bin\tsx.cmd'
    if (-not (Test-Path -LiteralPath $tsx)) {
        Write-Fail "tsx not found at $tsx — run npm install in review/api (or build dist/)."
        exit 1
    }
    $apiCmd = "& `"$tsx`" `"$(Join-Path $apiDir 'src\index.ts')`""
    Write-Info "Starting API (tsx): src/index.ts"
}

$apiProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
    "Set-Location -LiteralPath '$apiDir'; `$env:REVIEW_DB_PATH='$DatabasePath'; `$env:REVIEW_API_PORT='$ApiPort'; `$env:REVIEW_API_HOST='$($env:REVIEW_API_HOST)'; $apiCmd *>> '$apiLog'"
) -PassThru -WindowStyle Hidden

# --- start Web ---
$viteBin = Join-Path $webDir 'node_modules\.bin\vite.cmd'
if (-not (Test-Path -LiteralPath $viteBin)) {
    Stop-Process -Id $apiProc.Id -Force -ErrorAction SilentlyContinue
    Write-Fail "vite not found at $viteBin — run npm install in review/web."
    exit 1
}

if ($ProductionWeb) {
    $webDist = Join-Path $webDir 'dist'
    if (-not (Test-Path -LiteralPath $webDist)) {
        Stop-Process -Id $apiProc.Id -Force -ErrorAction SilentlyContinue
        Write-Fail "ProductionWeb requested but review/web/dist missing. Run: npm run build (in review/web)"
        exit 1
    }
    $webCmd = "& `"$viteBin`" preview --host 127.0.0.1 --port $WebPort"
    Write-Info "Starting Web (vite preview) on $WebPort"
} else {
    $webCmd = "& `"$viteBin`" --host 127.0.0.1 --port $WebPort"
    Write-Info "Starting Web (vite) on $WebPort"
}

$webProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
    "Set-Location -LiteralPath '$webDir'; $webCmd *>> '$webLog'"
) -PassThru -WindowStyle Hidden

# Wait briefly and discover child node PIDs
Start-Sleep -Seconds 2

function Get-ChildNodePids([int]$ParentPid) {
    $found = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentPid" -ErrorAction SilentlyContinue
        foreach ($p in @($procs)) {
            if ($p.Name -match '^(node|tsx)') { $found += [int]$p.ProcessId }
            $found += Get-ChildNodePids -ParentPid ([int]$p.ProcessId)
        }
    } catch { }
    return $found
}

$apiNodePids = @(Get-ChildNodePids -ParentPid $apiProc.Id | Select-Object -Unique)
$webNodePids = @(Get-ChildNodePids -ParentPid $webProc.Id | Select-Object -Unique)
# Fallback: parent powershell if children not yet visible
$apiTrack = if ($apiNodePids.Count) { $apiNodePids[0] } else { $apiProc.Id }
$webTrack = if ($webNodePids.Count) { $webNodePids[0] } else { $webProc.Id }

$pidPayload = [ordered]@{
    startedAt = (Get-Date).ToUniversalTime().ToString('o')
    databasePath = $DatabasePath
    apiPort = $ApiPort
    webPort = $WebPort
    apiShellPid = $apiProc.Id
    webShellPid = $webProc.Id
    apiPid = $apiTrack
    webPid = $webTrack
    apiNodePids = @($apiNodePids)
    webNodePids = @($webNodePids)
    apiLog = $apiLog
    webLog = $webLog
}
$pidPayload | ConvertTo-Json | Set-Content -LiteralPath $pidFile -Encoding UTF8

# --- readiness ---
$deadline = (Get-Date).AddSeconds(45)
$apiReady = $false
$webReady = $false
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
    if ($apiReady -and $webReady) { break }
    Start-Sleep -Milliseconds 500
}

if (-not $apiReady) {
    Write-Fail "API did not become ready on port $ApiPort. See log: $apiLog"
    & (Join-Path $RepoRoot 'Stop-FindSeriesReview.ps1')
    exit 1
}
if (-not $webReady) {
    Write-Fail "Web did not become ready on port $WebPort. See log: $webLog"
    & (Join-Path $RepoRoot 'Stop-FindSeriesReview.ps1')
    exit 1
}

Write-Ok "API ready: http://127.0.0.1:$ApiPort"
Write-Ok "Web ready: http://127.0.0.1:$WebPort"
Write-Ok "PID file: $pidFile"

if (-not $SkipBrowser) {
    Start-Process "http://127.0.0.1:$WebPort/"
}

Write-Ok "Started. Stop with: .\Stop-FindSeriesReview.ps1"
