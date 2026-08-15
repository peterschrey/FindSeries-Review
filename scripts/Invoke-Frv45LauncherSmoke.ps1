<#
.SYNOPSIS
  Local FRV-45 launcher lifecycle smoke (Windows). Not for flaky CI.

.DESCRIPTION
  Uses review-dev-mini.db only. Verifies Start / Double-Start / Stop / Restart,
  stale PID, PID-reuse safety, port conflict, partial failure, non-default ports,
  and log file presence.

.EXAMPLE
  .\scripts\Invoke-Frv45LauncherSmoke.ps1
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = 'C:\Temp\FindSeries-Review-Test\review-dev-mini.db',
    [int]$ApiPort = 8787,
    [int]$WebPort = 5173
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $root 'scripts\ReviewLauncherCommon.ps1')

function Write-Step([string]$Message) { Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Assert([bool]$Cond, [string]$Msg) {
    if (-not $Cond) { throw "ASSERT FAIL: $Msg" }
    Write-Host "PASS $Msg" -ForegroundColor Green
}

function Wait-HttpOk([string]$Url, [int]$Seconds = 40) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Invoke-Start([int]$UseApiPort, [int]$UseWebPort, [switch]$ExpectFail) {
    $startScript = Join-Path $root 'Start-FindSeriesReview.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript `
        -DatabasePath $DatabasePath `
        -ApiPort $UseApiPort `
        -WebPort $UseWebPort `
        -SkipBrowser
    $code = $LASTEXITCODE
    if ($ExpectFail) {
        Assert ($code -ne 0) "Start expected to fail (exit $code)"
    } else {
        Assert ($code -eq 0) "Start exit 0 (got $code)"
    }
}

function Invoke-Stop([int]$UseApiPort, [int]$UseWebPort) {
    & (Join-Path $root 'Stop-FindSeriesReview.ps1') -ApiPort $UseApiPort -WebPort $UseWebPort -CleanOrphans
}

$DatabasePath = [IO.Path]::GetFullPath($DatabasePath)
Assert (Test-Path -LiteralPath $DatabasePath) "mini DB exists: $DatabasePath"
Assert (-not (Test-IsProductionDbPath -Path $DatabasePath)) 'not production DB'

$pidFile = Get-ReviewPidFilePath -RepoRoot $root
$logDir = Get-ReviewLogDir -RepoRoot $root

Write-Step '0) Ensure clean slate'
Invoke-Stop -UseApiPort $ApiPort -UseWebPort $WebPort
Assert (Test-PortFree -Port $ApiPort) "API port $ApiPort free before smoke"
Assert (Test-PortFree -Port $WebPort) "Web port $WebPort free before smoke"
Assert (-not (Test-Path -LiteralPath $pidFile)) 'no PID file before smoke'

Write-Step '1) Start'
$logsBefore = @(Get-ChildItem -LiteralPath $logDir -Filter 'api-*.log' -ErrorAction SilentlyContinue)
Invoke-Start -UseApiPort $ApiPort -UseWebPort $WebPort
Assert (Wait-HttpOk "http://127.0.0.1:$ApiPort/api/projects") 'API ready (direct)'
Assert (Wait-HttpOk "http://127.0.0.1:$WebPort/") 'Web ready'
Assert (Wait-HttpOk "http://127.0.0.1:$WebPort/api/projects") 'Web proxy /api/projects ready'
Assert (Test-Path -LiteralPath $pidFile) 'PID file present after start'
$state = Read-ReviewPidState -PidFile $pidFile
Assert ($null -ne $state.tracked -and @($state.tracked).Count -ge 1) 'PID file contains tracked identities'
$apiLogs = @(Get-ChildItem -LiteralPath $logDir -Filter 'api-*.log' | Sort-Object LastWriteTime -Descending)
$webLogs = @(Get-ChildItem -LiteralPath $logDir -Filter 'web-*.log' | Sort-Object LastWriteTime -Descending)
Assert ($apiLogs.Count -gt $logsBefore.Count -or $apiLogs.Count -ge 1) 'API log file present'
Assert ($webLogs.Count -ge 1) 'Web log file present'
Write-Host "  Latest API log: $($apiLogs[0].FullName)"
Write-Host "  Latest Web log: $($webLogs[0].FullName)"

Write-Step '2) Double Start rejected'
Invoke-Start -UseApiPort $ApiPort -UseWebPort $WebPort -ExpectFail
Assert (Wait-HttpOk "http://127.0.0.1:$ApiPort/api/projects" -Seconds 5) 'original API still up after double-start reject'

Write-Step '3) Stop'
Invoke-Stop -UseApiPort $ApiPort -UseWebPort $WebPort
Start-Sleep -Seconds 1
Assert (-not (Test-Path -LiteralPath $pidFile)) 'PID file removed'
Assert (Test-PortFree -Port $ApiPort) "API port $ApiPort free after stop"
Assert (Test-PortFree -Port $WebPort) "Web port $WebPort free after stop"

Write-Step '4) Restart'
Invoke-Start -UseApiPort $ApiPort -UseWebPort $WebPort
Assert (Wait-HttpOk "http://127.0.0.1:$ApiPort/api/projects") 'API ready after restart'
Assert (Wait-HttpOk "http://127.0.0.1:$WebPort/api/projects") 'Web proxy ready after restart'
Invoke-Stop -UseApiPort $ApiPort -UseWebPort $WebPort
Start-Sleep -Seconds 1

Write-Step '5) Stale PID (nonexistent) handled'
$fake = [ordered]@{
    startedAt = (Get-Date).ToUniversalTime().ToString('o')
    apiPort = $ApiPort
    webPort = $WebPort
    apiShellPid = 999999
    webShellPid = 999998
    apiPid = 999997
    webPid = 999996
    apiNodePids = @(999997)
    webNodePids = @(999996)
    tracked = @(
        @{
            role = 'api'
            pid = 999997
            processName = 'node'
            creationTimeUtc = '2000-01-01T00:00:00.0000000Z'
            commandLine = 'stale-nonexistent'
        }
    )
    apiLog = 'stale-api.log'
    webLog = 'stale-web.log'
}
$fake | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pidFile -Encoding UTF8
Invoke-Start -UseApiPort $ApiPort -UseWebPort $WebPort
Assert (Wait-HttpOk "http://127.0.0.1:$ApiPort/api/projects") 'API ready after stale PID cleanup'
Invoke-Stop -UseApiPort $ApiPort -UseWebPort $WebPort
Start-Sleep -Seconds 1

Write-Step '5b) PID reuse / foreign process safety'
$foreign = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
) -PassThru -WindowStyle Hidden
try {
    Assert ($null -ne (Get-Process -Id $foreign.Id -ErrorAction SilentlyContinue)) "foreign sleep PID $($foreign.Id) running"
    $wrongIdentity = [ordered]@{
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        apiPort = $ApiPort
        webPort = $WebPort
        apiShellPid = $foreign.Id
        webShellPid = $foreign.Id
        apiPid = $foreign.Id
        webPid = $foreign.Id
        apiNodePids = @($foreign.Id)
        webNodePids = @($foreign.Id)
        tracked = @(
            @{
                role = 'apiShell'
                pid = $foreign.Id
                processName = 'node'
                creationTimeUtc = '1999-01-01T00:00:00.0000000Z'
                commandLine = 'NOT-A-MATCHING-IDENTITY'
            }
        )
        apiLog = 'reuse-stale-api.log'
        webLog = 'reuse-stale-web.log'
    }
    $wrongIdentity | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pidFile -Encoding UTF8
    Invoke-Stop -UseApiPort $ApiPort -UseWebPort $WebPort
    Assert (-not (Test-Path -LiteralPath $pidFile)) 'stale reuse PID file removed'
    Assert ($null -ne (Get-Process -Id $foreign.Id -ErrorAction SilentlyContinue)) "foreign PID $($foreign.Id) still alive after Stop"
} finally {
    if (Get-Process -Id $foreign.Id -ErrorAction SilentlyContinue) {
        Stop-ProcessTree -RootPid $foreign.Id -Label 'foreign-test'
        try { Wait-Process -Id $foreign.Id -Timeout 5 -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 300
        if (Get-Process -Id $foreign.Id -ErrorAction SilentlyContinue) {
            Stop-Process -Id $foreign.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
        }
    }
}
Assert ($null -eq (Get-Process -Id $foreign.Id -ErrorAction SilentlyContinue)) 'foreign test process cleaned up by smoke'

Write-Step '6) Port conflict - foreign listener preserved'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $ApiPort)
$listener.Start()
try {
    Invoke-Start -UseApiPort $ApiPort -UseWebPort $WebPort -ExpectFail
    Assert (-not (Test-Path -LiteralPath $pidFile)) 'no PID file after port-conflict refuse'
    $still = @(Get-PortListeners -Port $ApiPort)
    Assert ($still.Count -gt 0) 'foreign API listener still present'
} finally {
    $listener.Stop()
}
Start-Sleep -Milliseconds 300
Assert (Test-PortFree -Port $ApiPort) 'API port free after foreign listener closed'

Write-Step '7) Partial failure cleanup (vite missing after API would start)'
$vite = Join-Path $root 'review\web\node_modules\.bin\vite.cmd'
$viteBak = "$vite.frv45bak"
Assert (Test-Path -LiteralPath $vite) 'vite.cmd present for rename test'
Rename-Item -LiteralPath $vite -NewName (Split-Path $viteBak -Leaf)
try {
    Invoke-Start -UseApiPort $ApiPort -UseWebPort $WebPort -ExpectFail
} finally {
    if (Test-Path -LiteralPath $viteBak) {
        Rename-Item -LiteralPath $viteBak -NewName 'vite.cmd' -Force
    }
}
Start-Sleep -Seconds 1
Assert (-not (Test-Path -LiteralPath $pidFile)) 'no PID file after partial failure'
Assert (Test-PortFree -Port $ApiPort) "no orphan API on $ApiPort after partial failure"
Assert (Test-PortFree -Port $WebPort) "no orphan Web on $WebPort after partial failure"

Write-Step '8) Logs still findable'
Assert ((Get-ChildItem -LiteralPath $logDir -Filter 'api-*.log').Count -ge 1) 'API logs in log dir'
Assert ((Get-ChildItem -LiteralPath $logDir -Filter 'web-*.log').Count -ge 1) 'Web logs in log dir'
Write-Host "Log directory: $logDir"

Write-Step '9) Non-default ApiPort + WebPort (dynamic free ports)'
$altApi = Find-FreeTcpPort
$altWeb = Find-FreeTcpPort
while ($altWeb -eq $altApi) { $altWeb = Find-FreeTcpPort }
Write-Host "  Using ApiPort=$altApi WebPort=$altWeb"
Invoke-Start -UseApiPort $altApi -UseWebPort $altWeb
Assert (Wait-HttpOk "http://127.0.0.1:$altApi/api/projects") "direct API ready on $altApi"
Assert (Wait-HttpOk "http://127.0.0.1:$altWeb/api/projects") "web proxy /api/projects ready on $altWeb -> $altApi"
Invoke-Stop -UseApiPort $altApi -UseWebPort $altWeb
Start-Sleep -Seconds 1
Assert (-not (Test-Path -LiteralPath $pidFile)) 'PID file removed after alt-port stop'
Assert (Test-PortFree -Port $altApi) "alt API port $altApi free after stop"
Assert (Test-PortFree -Port $altWeb) "alt Web port $altWeb free after stop"

Write-Host ""
Write-Host "PASS FRV-45 launcher smoke" -ForegroundColor Green
exit 0
