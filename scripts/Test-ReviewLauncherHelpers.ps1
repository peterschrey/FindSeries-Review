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

$free = Find-FreeTcpPort
Assert ($free -gt 0) "Find-FreeTcpPort returned $free"

# Process identity: current process matches itself; wrong creation time does not
$self = Get-ProcessIdentity -ProcessId $PID
Assert ($null -ne $self) 'Get-ProcessIdentity for current process'
Assert (Test-ProcessIdentityMatch -Expected $self -ProcessId $PID) 'identity matches self'
$wrong = [ordered]@{
    pid = $PID
    processName = $self.processName
    creationTimeUtc = '1990-01-01T00:00:00.0000000Z'
    commandLine = $self.commandLine
}
Assert (-not (Test-ProcessIdentityMatch -Expected $wrong -ProcessId $PID)) 'identity rejects wrong creationTime'
Assert (-not (Test-ProcessIdentityMatch -Expected $null -ProcessId $PID)) 'identity rejects null expected'

# Legacy state without tracked[] yields no alive PIDs (PID-alone unsafe)
$legacy = [pscustomobject]@{ apiPid = $PID; webPid = $PID }
Assert ((@(Get-AliveSessionPids -State $legacy)).Count -eq 0) 'legacy pid file without tracked is not treated as alive session'

if ($fails -gt 0) {
    Write-Host "FAIL Review launcher helpers ($fails)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASS Review launcher helpers' -ForegroundColor Green
exit 0
