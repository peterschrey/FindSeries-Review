<#
.SYNOPSIS
  One-time prepare / local packaging for FindSeries Review on Windows (FRV-45).

.DESCRIPTION
  Checks Node.js, installs review/shared|api|web dependencies, and builds
  shared + API + Web production artifacts. After this, Start-FindSeriesReview.ps1
  prefers built API + vite preview.

  No global npm install, Electron, Docker, or Windows Service.

.PARAMETER SkipInstall
  Skip npm ci/install (use existing node_modules).

.PARAMETER SkipBuild
  Skip production builds.

.EXAMPLE
  .\Prepare-FindSeriesReview.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipInstall,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Invoke-NpmIn {
    param([string]$Dir, [string[]]$NpmArgs)
    Push-Location $Dir
    try {
        & npm @NpmArgs
        if ($LASTEXITCODE -ne 0) { throw "npm $($NpmArgs -join ' ') failed in $Dir (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

Write-Info "FindSeries Review prepare (local packaging)"
Write-Info "  Repo: $RepoRoot"

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if (-not $nodeCmd -or -not $npmCmd) {
    Write-Fail "Node.js/npm not found on PATH. Install Node.js >= 20 from https://nodejs.org and re-run."
    exit 1
}
$nodeVer = (& node -v) -replace '^v', ''
$nodeMajor = [int](($nodeVer -split '\.')[0])
if ($nodeMajor -lt 20) {
    Write-Fail "Node.js v$nodeVer detected; need >= 20."
    exit 1
}
Write-Ok "Node $nodeVer / npm $(& npm -v)"

$packages = @(
    @{ Name = 'shared'; Path = (Join-Path $RepoRoot 'review\shared') },
    @{ Name = 'api'; Path = (Join-Path $RepoRoot 'review\api') },
    @{ Name = 'web'; Path = (Join-Path $RepoRoot 'review\web') }
)

foreach ($p in $packages) {
    if (-not (Test-Path -LiteralPath (Join-Path $p.Path 'package.json'))) {
        Write-Fail "Missing package.json in $($p.Path)"
        exit 1
    }
}

if (-not $SkipInstall) {
    foreach ($p in $packages) {
        $lock = Join-Path $p.Path 'package-lock.json'
        Write-Info "Installing review/$($p.Name)..."
        if (Test-Path -LiteralPath $lock) {
            Invoke-NpmIn -Dir $p.Path -NpmArgs @('ci', '--no-fund', '--no-audit')
        } else {
            Invoke-NpmIn -Dir $p.Path -NpmArgs @('install', '--no-fund', '--no-audit')
        }
    }
    Write-Ok "Dependencies installed"
} else {
    Write-Info "SkipInstall: using existing node_modules"
}

if (-not $SkipBuild) {
    Write-Info "Building shared..."
    Invoke-NpmIn -Dir $packages[0].Path -NpmArgs @('run', 'build')
    Write-Info "Building api..."
    Invoke-NpmIn -Dir $packages[1].Path -NpmArgs @('run', 'build')
    Write-Info "Building web..."
    Invoke-NpmIn -Dir $packages[2].Path -NpmArgs @('run', 'build')
    Write-Ok "Production builds ready"
} else {
    Write-Info "SkipBuild: leaving dist/ as-is"
}

$apiDist = Join-Path $RepoRoot 'review\api\dist\index.js'
$webDist = Join-Path $RepoRoot 'review\web\dist\index.html'
if ((Test-Path -LiteralPath $apiDist) -and (Test-Path -LiteralPath $webDist)) {
    Write-Ok "Artifacts OK: review/api/dist + review/web/dist"
} else {
    Write-Fail "Expected build artifacts missing. Re-run without -SkipBuild."
    exit 1
}

Write-Ok @"

Prepare complete. Typical workflow:
  .\Start-FindSeriesReview.ps1
  .\Stop-FindSeriesReview.ps1

Default DB: C:\Temp\FindSeries-Review-Test\review-dev-mini.db
(Never the productive FindSeries DB.)
"@
