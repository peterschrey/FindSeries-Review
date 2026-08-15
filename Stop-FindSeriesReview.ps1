<#
.SYNOPSIS
  Stops FindSeries Review MVP processes started by Start-FindSeriesReview.ps1.

.DESCRIPTION
  Reads the PID file written by the launcher and terminates only that Review
  session (shell wrappers + child node/tsx trees). Never blindly kills all
  node.exe / powershell.exe. Does not kill foreign listeners on the ports.

.PARAMETER PidFile
  Optional explicit path to findseries-review.pid.

.PARAMETER ApiPort
  Fallback port for status reporting only (default 8787).

.PARAMETER WebPort
  Fallback port for status reporting only (default 5173).

.EXAMPLE
  .\Stop-FindSeriesReview.ps1

.NOTES
  Pair with: .\Start-FindSeriesReview.ps1
#>
[CmdletBinding()]
param(
    [string]$PidFile,
    [int]$ApiPort = 8787,
    [int]$WebPort = 5173,
    # Only kill listeners whose command line points at this repo's review/api|web.
    # Never kills unrelated node/Cursor processes.
    [switch]$CleanOrphans
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
. (Join-Path $RepoRoot 'scripts\ReviewLauncherCommon.ps1')

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }

$PidFile = Get-ReviewPidFilePath -RepoRoot $RepoRoot -Explicit $PidFile

Write-Info "FindSeries Review stop"
Write-Info "  PID file: $PidFile"

$stopped = @()
if (Test-Path -LiteralPath $PidFile) {
    $state = Read-ReviewPidState -PidFile $PidFile
    if ($state) {
        if ($state.apiPort) { $ApiPort = [int]$state.apiPort }
        if ($state.webPort) { $WebPort = [int]$state.webPort }
        if ($state.apiLog) { Write-Info "  API log was: $($state.apiLog)" }
        if ($state.webLog) { Write-Info "  Web log was: $($state.webLog)" }
    } else {
        Write-Warn "PID file present but unreadable/corrupt - will remove after best-effort stop"
    }

    $stopped = @(Clear-ReviewSessionFromPidFile -PidFile $PidFile)
    if ($stopped.Count -gt 0) {
        Write-Ok "Stopped session PIDs: $($stopped -join ', ')"
    } else {
        Write-Info "No living session PIDs (stale PID file cleaned)"
    }
    Write-Ok "Removed PID file"
} else {
    Write-Warn "No PID file at $PidFile (nothing session-owned to stop)"
}

if ($CleanOrphans) {
    Write-Info "CleanOrphans: stopping listeners whose command line matches this repo review stack"
    $orphans = @(Stop-ReviewOrphanListeners -RepoRoot $RepoRoot -ApiPort $ApiPort -WebPort $WebPort)
    if ($orphans.Count) {
        Write-Ok "Stopped review orphans: $($orphans -join ', ')"
    } else {
        Write-Info "No review-stack orphans on ports $ApiPort / $WebPort"
    }
}

# Settle briefly, then report port status - never kill foreign listeners
Start-Sleep -Milliseconds 500
$leftApi = @(Get-PortListeners -Port $ApiPort)
$leftWeb = @(Get-PortListeners -Port $WebPort)

if ($leftApi.Count -eq 0 -and $leftWeb.Count -eq 0) {
    Write-Ok "Ports $ApiPort / $WebPort are free"
} else {
    if ($leftApi.Count) {
        Write-Warn "API port $ApiPort still listening (foreign or leftover - not killed): $(Get-PortOccupantSummary -Port $ApiPort)"
    }
    if ($leftWeb.Count) {
        Write-Warn "Web port $WebPort still listening (foreign or leftover - not killed): $(Get-PortOccupantSummary -Port $WebPort)"
    }
    Write-Warn "If these are your Review processes without a PID file, stop them manually by PID."
}

Write-Ok "Stopped"
