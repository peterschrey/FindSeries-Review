# FRV-42 one-command Review release gate (local).
# Runs: shared build → api tests → web tests → typechecks → production builds.
# Uses synthetic DB fixtures only (never the 19GB production DB).
[CmdletBinding()]
param(
    [switch]$SkipInstall,
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

function Step([string]$Label, [scriptblock]$Action) {
    Write-Host ""
    Write-Host "=== $Label ===" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "Step failed: $Label (exit $LASTEXITCODE)"
    }
}

Write-Host "FindSeries Review test gate (repo: $root)" -ForegroundColor Green

if (-not $SkipInstall) {
    Step 'npm install review/shared' {
        Push-Location (Join-Path $root 'review\shared')
        try { npm install --no-fund --no-audit } finally { Pop-Location }
    }
    Step 'npm install review/api' {
        Push-Location (Join-Path $root 'review\api')
        try { npm install --no-fund --no-audit } finally { Pop-Location }
    }
    Step 'npm install review/web' {
        Push-Location (Join-Path $root 'review\web')
        try { npm install --no-fund --no-audit } finally { Pop-Location }
    }
}

Step 'shared build' {
    Push-Location (Join-Path $root 'review\shared')
    try { npm run build } finally { Pop-Location }
}

Step 'api tests (synthetic DB)' {
    Push-Location (Join-Path $root 'review\api')
    try { npm test } finally { Pop-Location }
}

Step 'web tests' {
    Push-Location (Join-Path $root 'review\web')
    try { npm test } finally { Pop-Location }
}

Step 'shared typecheck' {
    Push-Location (Join-Path $root 'review\shared')
    try { npm run typecheck } finally { Pop-Location }
}

Step 'api typecheck' {
    Push-Location (Join-Path $root 'review\api')
    try { npm run typecheck } finally { Pop-Location }
}

Step 'web typecheck' {
    Push-Location (Join-Path $root 'review\web')
    try { npm run typecheck } finally { Pop-Location }
}

if (-not $SkipBuild) {
    Step 'api production build' {
        Push-Location (Join-Path $root 'review\api')
        try { npm run build } finally { Pop-Location }
    }
    Step 'web production build' {
        Push-Location (Join-Path $root 'review\web')
        try { npm run build } finally { Pop-Location }
    }
}

Write-Host ""
Write-Host "PASS Review test gate" -ForegroundColor Green
