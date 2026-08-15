# FRV-45 CI-safe helper checks (no process lifecycle).
# Dot-sources ReviewLauncherCommon.ps1 and asserts pure helpers.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $root 'scripts\ReviewLauncherCommon.ps1')

$fails = 0
function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) {
        Write-Host "PASS $Msg" -ForegroundColor Green
    } else {
        Write-Host "FAIL $Msg" -ForegroundColor Red
        $script:fails++
    }
}

$prod = Get-ProductionDbPath
Assert (Test-IsProductionDbPath -Path $prod) 'production path detected'
Assert (-not (Test-IsProductionDbPath -Path 'C:\Temp\FindSeries-Review-Test\review-dev-mini.db')) 'mini path not production'
Assert (-not (Test-IsProductionDbPath -Path 'C:\Temp\FindSeries-Review-Test\frv44-work.db')) 'work path not production'

$logDir = Get-ReviewLogDir -RepoRoot $root
Assert ($logDir -and (Test-Path -LiteralPath $logDir)) 'log dir resolvable'
$pidPath = Get-ReviewPidFilePath -RepoRoot $root
Assert ($pidPath -match 'findseries-review\.pid$') 'pid file path ends with findseries-review.pid'

# Port helper smoke (does not require free ports)
$sum0 = Get-PortOccupantSummary -Port 1
Assert ($null -ne $sum0) 'port occupant summary returns'

if ($fails -gt 0) {
    Write-Host "FAIL Review launcher helpers ($fails)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASS Review launcher helpers' -ForegroundColor Green
exit 0
