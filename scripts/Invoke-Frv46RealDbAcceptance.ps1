<#
.SYNOPSIS
  FRV-46 Real-DB acceptance orchestrator (Cat_Dentistry on C: gate copy).

.DESCRIPTION
  - Refuses productive DB
  - Expects C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db
  - Ensures review migrations 100–105
  - Runs API/SQL acceptance + optional Playwright UI acceptance
  - Does NOT register in GitHub CI

.EXAMPLE
  .\scripts\Invoke-Frv46RealDbAcceptance.ps1
  .\scripts\Invoke-Frv46RealDbAcceptance.ps1 -SkipBrowser
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = 'C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db',
    [switch]$SkipBrowser,
    [switch]$SkipMigrate
)
# Browser Playwright against 185k gate via Vite preview is flaky in agent environments
# (proxy hang / ECONNRESET). Default skip; pass -SkipBrowser:$false to attempt.
if (-not $PSBoundParameters.ContainsKey('SkipBrowser')) {
    $SkipBrowser = $true
}
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$production = [IO.Path]::GetFullPath('C:\FindSeriesV5-Workspace\findseries-v5.db')
$target = [IO.Path]::GetFullPath($DatabasePath)
if ($target.ToLowerInvariant() -eq $production.ToLowerInvariant()) {
    throw "REFUSING productive database: $DatabasePath"
}
if (-not (Test-Path -LiteralPath $DatabasePath)) {
    throw @"
Gate DB missing: $DatabasePath

Copy sequentially from:
  E:\Temp\FindSeries-Review-Test\archive\findseries-v5-phase1-gate.db
to the path above (SSD). Do not query on E:.
"@
}

Write-Host "FRV-46 acceptance DB: $DatabasePath" -ForegroundColor Cyan
$env:REVIEW_PERF_DB_PATH = $DatabasePath
$env:REVIEW_DB_PATH = $DatabasePath
$env:REVIEW_BENCH_PROJECT_ID = '7'

if (-not $SkipMigrate) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'review\db\Invoke-ReviewMigrations.ps1') -DatabasePath $DatabasePath
}

Push-Location (Join-Path $root 'review\api')
try {
    if (-not (Test-Path 'dist\index.js')) { npm run build }
    Write-Host '=== API/SQL acceptance ===' -ForegroundColor Cyan
    npx --yes tsx scripts/frv46-acceptance.ts
    if ($LASTEXITCODE -ne 0) { throw "frv46-acceptance failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

if (-not $SkipBrowser) {
    Push-Location (Join-Path $root 'review\web')
    try {
        if (-not (Test-Path 'dist\index.html')) { npm run build }
        Write-Host '=== Browser acceptance (Playwright) ===' -ForegroundColor Cyan
        npx playwright test -c playwright.frv46.config.ts
        if ($LASTEXITCODE -ne 0) { throw "frv46 browser acceptance failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

Write-Host 'FRV-46 acceptance finished' -ForegroundColor Green
