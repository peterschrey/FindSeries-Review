# Shared helpers for Start-/Stop-FindSeriesReview.ps1 (FRV-45).
# Dot-source only; do not execute directly.

function Get-ReviewRepoRoot {
    param([string]$Hint)
    if ($Hint) { return $Hint }
    if ($PSScriptRoot) {
        $parent = Split-Path -Parent $PSScriptRoot
        if (Test-Path (Join-Path $parent 'Start-FindSeriesReview.ps1')) { return $parent }
        return $PSScriptRoot
    }
    return (Get-Location).Path
}

function Get-ReviewLogDir {
    param([string]$RepoRoot)
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

function Get-ReviewPidFilePath {
    param([string]$RepoRoot, [string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        return [IO.Path]::GetFullPath($Explicit)
    }
    return (Join-Path (Get-ReviewLogDir -RepoRoot $RepoRoot) 'findseries-review.pid')
}

function Get-ProductionDbPath {
    return [IO.Path]::GetFullPath('C:\FindSeriesV5-Workspace\findseries-v5.db')
}

function Test-IsProductionDbPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    return $full -eq (Get-ProductionDbPath).ToLowerInvariant()
}

function Find-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-PortListeners {
    param([int]$Port)
    try {
        return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    } catch {
        # Fallback when NetTCPIP module cannot load in the current host.
        $rows = @()
        $netstat = & netstat.exe -ano -p tcp 2>$null
        foreach ($line in $netstat) {
            if ($line -notmatch 'LISTENING') { continue }
            if ($line -notmatch ":$Port\s+") { continue }
            if ($line -match '\s+(\d+)\s*$') {
                $rows += [pscustomobject]@{ OwningProcess = [int]$Matches[1]; LocalPort = $Port }
            }
        }
        return $rows
    }
}

function Test-PortFree {
    param([int]$Port)
    return -not (Get-PortListeners -Port $Port)
}

function Get-PortOccupantSummary {
    param([int]$Port)
    $lines = @()
    foreach ($c in (Get-PortListeners -Port $Port)) {
        $owningPid = [int]$c.OwningProcess
        $proc = Get-Process -Id $owningPid -ErrorAction SilentlyContinue
        if ($proc) {
            $lines += "PID $owningPid ($($proc.ProcessName))"
        } else {
            $lines += "PID $owningPid"
        }
    }
    if ($lines.Count -eq 0) { return '(none)' }
    return ($lines -join ', ')
}

function Get-ChildProcessIds {
    param([int]$RootPid)
    $ids = @()
    if ($RootPid -le 0) { return $ids }
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$RootPid" -ErrorAction SilentlyContinue
        foreach ($c in @($children)) {
            $childId = [int]$c.ProcessId
            $ids += $childId
            $ids += Get-ChildProcessIds -RootPid $childId
        }
    } catch { }
    return $ids
}

function Get-ChildNodePids {
    param([int]$ParentPid)
    $found = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentPid" -ErrorAction SilentlyContinue
        foreach ($p in @($procs)) {
            if ($p.Name -match '^(node|tsx)') { $found += [int]$p.ProcessId }
            $found += Get-ChildNodePids -ParentPid ([int]$p.ProcessId)
        }
    } catch { }
    return @($found | Select-Object -Unique)
}

function Get-ProcessIdentity {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    $startUtc = $null
    try {
        if ($proc.StartTime) {
            $startUtc = $proc.StartTime.ToUniversalTime().ToString('o')
        }
    } catch { }
    return [ordered]@{
        pid              = $ProcessId
        processName      = $proc.ProcessName
        creationTimeUtc  = $startUtc
        commandLine      = $(if ($cim) { $cim.CommandLine } else { $null })
    }
}

function Test-ProcessIdentityMatch {
    param(
        $Expected,
        [int]$ProcessId
    )
    if (-not $Expected) { return $false }
    $expectedPid = 0
    try { $expectedPid = [int]$Expected.pid } catch { return $false }
    if ($expectedPid -le 0 -or $ProcessId -ne $expectedPid) { return $false }

    $live = Get-ProcessIdentity -ProcessId $ProcessId
    if (-not $live) { return $false }

    $expName = [string]$Expected.processName
    $liveName = [string]$live.processName
    if ($expName -and $liveName -and ($expName -ne $liveName)) { return $false }

    $expCreated = [string]$Expected.creationTimeUtc
    $liveCreated = [string]$live.creationTimeUtc
    if ([string]::IsNullOrWhiteSpace($expCreated) -or [string]::IsNullOrWhiteSpace($liveCreated)) {
        # Without a creation timestamp we cannot prove identity — refuse match.
        return $false
    }
    try {
        $expDt = [DateTimeOffset]::Parse($expCreated).UtcDateTime
        $liveDt = [DateTimeOffset]::Parse($liveCreated).UtcDateTime
        # Allow tiny clock/rounding skew (1s).
        if ([Math]::Abs(($expDt - $liveDt).TotalSeconds) -gt 1) { return $false }
    } catch {
        return $false
    }

    $expCmd = [string]$Expected.commandLine
    $liveCmd = [string]$live.commandLine
    if (-not [string]::IsNullOrWhiteSpace($expCmd) -and -not [string]::IsNullOrWhiteSpace($liveCmd)) {
        if ($expCmd -ne $liveCmd) { return $false }
    }
    return $true
}

function Get-TrackedSessionEntries {
    param($State)
    $entries = @()
    if (-not $State) { return $entries }

    if ($State.tracked) {
        foreach ($t in @($State.tracked)) {
            if ($t) { $entries += $t }
        }
        return $entries
    }

    # Legacy pid files without identity metadata: treat as unmatched (do not kill by PID alone).
    return @()
}

function Stop-PidSafe {
    param([int]$ProcessId, [string]$Label = 'process')
    if ($ProcessId -le 0) { return }
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host "  $Label PID $ProcessId already gone" -ForegroundColor Cyan
        return
    }
    Write-Host "  Stopping $Label PID $ProcessId ($($proc.ProcessName))" -ForegroundColor Cyan
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    } catch {
        Write-Host "  Could not stop PID ${ProcessId}: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stop-ProcessTree {
    param([int]$RootPid, [string]$Label = 'process')
    if ($RootPid -le 0) { return }
    foreach ($childId in (Get-ChildProcessIds -RootPid $RootPid)) {
        Stop-PidSafe -ProcessId $childId -Label "$Label-child"
    }
    Stop-PidSafe -ProcessId $RootPid -Label $Label
}

function Read-ReviewPidState {
    param([string]$PidFile)
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    try {
        return Get-Content -LiteralPath $PidFile -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-AliveSessionPids {
    param($State)
    if (-not $State) { return @() }
    $alive = @()
    foreach ($entry in (Get-TrackedSessionEntries -State $State)) {
        $pidVal = 0
        try { $pidVal = [int]$entry.pid } catch { continue }
        if ($pidVal -le 0) { continue }
        if (Test-ProcessIdentityMatch -Expected $entry -ProcessId $pidVal) {
            $alive += $pidVal
        }
    }
    return @($alive | Select-Object -Unique)
}

function Clear-ReviewSessionFromPidFile {
    param([string]$PidFile)
    $stopped = @()
    $state = Read-ReviewPidState -PidFile $PidFile
    if ($state) {
        $entries = @(Get-TrackedSessionEntries -State $state)
        if ($entries.Count -eq 0 -and ($state.apiPid -or $state.webPid -or $state.apiShellPid -or $state.webShellPid)) {
            Write-Host "  PID file lacks process identity metadata - refusing to kill by PID alone (treating as stale)" -ForegroundColor Yellow
        }
        foreach ($entry in $entries) {
            $pidVal = 0
            try { $pidVal = [int]$entry.pid } catch { continue }
            if ($pidVal -le 0) { continue }
            if (-not (Get-Process -Id $pidVal -ErrorAction SilentlyContinue)) {
                Write-Host "  session PID $pidVal already gone" -ForegroundColor Cyan
                continue
            }
            if (Test-ProcessIdentityMatch -Expected $entry -ProcessId $pidVal) {
                $role = if ($entry.role) { [string]$entry.role } else { 'session' }
                Stop-ProcessTree -RootPid $pidVal -Label $role
                $stopped += $pidVal
            } else {
                Write-Host "  WARN: PID $pidVal does not match stored identity - leaving process alone (stale/reused PID)" -ForegroundColor Yellow
            }
        }
    }
    if (Test-Path -LiteralPath $PidFile) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    return @($stopped | ForEach-Object { [int]$_ })
}

function Test-IsReviewStackCommandLine {
    param([string]$CommandLine, [string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return $false
    }
    $normCmd = $CommandLine.Replace('/', '\').ToLowerInvariant()
    $normRoot = $RepoRoot.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    $apiMarker = ($normRoot + '\review\api').ToLowerInvariant()
    $webMarker = ($normRoot + '\review\web').ToLowerInvariant()
    return ($normCmd.Contains($apiMarker) -or $normCmd.Contains($webMarker))
}

function Stop-ReviewOrphanListeners {
    param(
        [string]$RepoRoot,
        [int]$ApiPort = 8787,
        [int]$WebPort = 5173
    )
    $stopped = @()
    foreach ($port in @($ApiPort, $WebPort)) {
        foreach ($c in (Get-PortListeners -Port $port)) {
            $owningPid = [int]$c.OwningProcess
            $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$owningPid" -ErrorAction SilentlyContinue
            if ($procInfo -and (Test-IsReviewStackCommandLine -CommandLine $procInfo.CommandLine -RepoRoot $RepoRoot)) {
                Write-Host "  Stopping review-stack orphan on port $port (PID $owningPid)" -ForegroundColor Cyan
                Stop-ProcessTree -RootPid $owningPid -Label 'orphan'
                $stopped += $owningPid
            }
        }
    }
    return @($stopped | Select-Object -Unique)
}
