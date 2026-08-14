# FindSeries HF66 live monitor: read-only dark charts, reused-rate telemetry and throughput scatter plots.
[CmdletBinding()]
param(
    [string]$Project='Zahnmedizin',
    [string]$Workspace,
    [string]$SqlitePath,
    [ValidateRange(2,60)][int]$RefreshSeconds=10,
    [ValidateRange(20,4000)][int]$Samples=2000,
    [ValidateSet('Gui','Console')][string]$Mode='Gui',
    [switch]$Once,
    [switch]$SelfTest,
    [string]$ReadyFile,
    [switch]$HideConsole
)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$script:MonitorLog=Join-Path $env:TEMP 'FindSeries-download-monitor-startup.log'

function Show-FsMonitorFatalError {
    param([string]$Message)
    $detail="$Message`r`n`r`nProtokoll: $script:MonitorLog"
    try{
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show(
            $detail,
            'FindSeries Download-Monitor',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }catch{
        try{Write-Error $detail -ErrorAction Continue}catch{}
    }
}

trap {
    $fatalMessage=$_.Exception.Message
    try{
        Add-Content -LiteralPath $script:MonitorLog -Encoding UTF8 -Value ("[{0}] Monitorstart fehlgeschlagen: {1}`r`n{2}`r`n" -f (Get-Date).ToString('o'),$fatalMessage,[string]$_.Exception.ToString())
    }catch{}
    if($SelfTest){
        try{Write-Error ("Download-Monitor-Selbsttest fehlgeschlagen: {0}" -f $fatalMessage) -ErrorAction Continue}catch{}
    }else{
        Show-FsMonitorFatalError -Message ("Der grafische Monitor konnte nicht gestartet werden: {0}" -f $fatalMessage)
    }
    exit 1
}

Import-Module (Join-Path $root 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $root
$diagnostics=Join-Path $Workspace 'Diagnostics'
if(-not(Test-Path -LiteralPath $diagnostics)){New-Item -ItemType Directory -Path $diagnostics -Force|Out-Null}
$script:MonitorLog=Join-Path $diagnostics 'download-monitor.log'
$monitorLog=$script:MonitorLog

# Exactly one monitor per project/workspace. FindSeries.ps1 and the updater may
# both request startup; this lock makes the second request a no-op.
$mutexBytes=[Text.Encoding]::UTF8.GetBytes(("{0}|{1}" -f $Workspace,$Project).ToLowerInvariant())
$mutexHasher=[Security.Cryptography.SHA256]::Create()
try{$mutexHash=([BitConverter]::ToString($mutexHasher.ComputeHash($mutexBytes))).Replace('-','').Substring(0,24)}finally{$mutexHasher.Dispose()}
$monitorMutexCreated=$false
$script:MonitorMutex=[Threading.Mutex]::new($true,("Local\FindSeriesDownloadMonitor_{0}" -f $mutexHash),[ref]$monitorMutexCreated)
if(-not $monitorMutexCreated){return}

function Resolve-FsMonitorSqlitePath {
    param([string]$ExplicitPath,[string]$ApplicationRoot,[string]$WorkspaceRoot)
    $candidates=[System.Collections.Generic.List[string]]::new()
    if(-not[string]::IsNullOrWhiteSpace($ExplicitPath)){$candidates.Add([IO.Path]::GetFullPath($ExplicitPath))}
    $candidates.Add((Join-Path $ApplicationRoot 'Tools\sqlite3.exe'))
    $candidates.Add((Join-Path $ApplicationRoot 'Tools\sqlite3'))
    $candidates.Add((Join-Path $WorkspaceRoot 'Tools\sqlite3.exe'))
    $candidates.Add((Join-Path $WorkspaceRoot 'Tools\sqlite3'))
    foreach($name in @('sqlite3.exe','sqlite3')){
        try{$command=Get-Command $name -ErrorAction Stop;if($null -ne $command){$candidates.Add([string]$command.Source)}}catch{}
    }
    foreach($candidate in $candidates){if(-not[string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)){return [IO.Path]::GetFullPath($candidate)}}
    throw 'sqlite3 wurde für den Monitor nicht gefunden.'
}

function ConvertTo-FsMonitorSqlLiteral {
    param([AllowNull()][object]$Value)
    if($null -eq $Value){return 'NULL'}
    return "'"+([string]$Value).Replace("'","''")+"'"
}

$db=Join-Path $Workspace 'findseries-v5.db'
$sqlite=Resolve-FsMonitorSqlitePath -ExplicitPath $SqlitePath -ApplicationRoot $root -WorkspaceRoot $Workspace
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw "FindSeries-Datenbank fehlt: $db"}

function Expand-FsMonitorRows {
    param([AllowNull()][object]$Value)
    if($null -eq $Value){return}
    if($Value -is [System.Array]){
        foreach($item in $Value){Expand-FsMonitorRows -Value $item}
        return
    }
    Write-Output $Value
}

function Get-FsMonitorScalar {
    param([AllowNull()][object]$Value)
    $current=$Value
    while($current -is [System.Array]){
        if($current.Count -eq 0){return $null}
        $current=$current[0]
    }
    return $current
}

function Invoke-FsMonitorQuery {
    param(
        [Parameter(Mandatory=$true)][string]$Sql,
        [ValidateRange(1000,30000)][int]$ExecutionTimeoutMs=20000,
        [ValidateRange(1,5)][int]$BusyRetries=3
    )
    $lastError=$null
    for($attempt=1;$attempt -le $BusyRetries;$attempt++){
        $process=$null
        try{
            $psi=New-Object Diagnostics.ProcessStartInfo
            $psi.FileName=$sqlite
            $psi.Arguments='-readonly -batch -bail "'+$db.Replace('"','""')+'"'
            $psi.UseShellExecute=$false
            $psi.CreateNoWindow=$true
            $psi.RedirectStandardInput=$true
            $psi.RedirectStandardOutput=$true
            $psi.RedirectStandardError=$true
            try{
                $utf8=New-Object Text.UTF8Encoding($false)
                $psi.StandardOutputEncoding=$utf8
                $psi.StandardErrorEncoding=$utf8
            }catch{}
            $process=New-Object Diagnostics.Process
            $process.StartInfo=$psi
            if(-not $process.Start()){throw 'sqlite3-Monitorprozess konnte nicht gestartet werden.'}
            $stdoutTask=$process.StandardOutput.ReadToEndAsync()
            $stderrTask=$process.StandardError.ReadToEndAsync()
            $input=New-Object Text.StringBuilder
            [void]$input.AppendLine('.timeout 10000')
            [void]$input.AppendLine('.bail on')
            [void]$input.AppendLine('.headers on')
            [void]$input.AppendLine('.mode json')
            [void]$input.AppendLine('PRAGMA query_only=ON;')
            [void]$input.AppendLine($Sql)
            $process.StandardInput.Write($input.ToString())
            $process.StandardInput.Close()
            if(-not $process.WaitForExit($ExecutionTimeoutMs)){
                try{$process.Kill()}catch{}
                throw "Read-only-Monitorabfrage nach $ExecutionTimeoutMs ms abgebrochen."
            }
            $process.WaitForExit()
            $stdout=$stdoutTask.Result
            $stderr=$stderrTask.Result
            if($process.ExitCode -ne 0){
                $message=if(-not[string]::IsNullOrWhiteSpace($stderr)){$stderr.Trim()}else{"sqlite3 ExitCode $($process.ExitCode)"}
                throw "SQLite-Monitorfehler: $message"
            }
            if([string]::IsNullOrWhiteSpace($stdout)){return @()}

            # Windows PowerShell 5.1 can preserve a JSON array as a nested
            # System.Object[]. Flatten it explicitly so chart rows and scalar
            # properties never receive Object[] values.
            $parsed=$stdout.Trim()|ConvertFrom-Json
            $flatRows=@(Expand-FsMonitorRows -Value $parsed)
            return $flatRows
        }catch{
            $lastError=$_
            $isBusy=($_.Exception.Message -match '(?i)database is locked|database is busy|SQLITE_BUSY|SQLITE_LOCKED')
            if(-not $isBusy -or $attempt -ge $BusyRetries){throw}
            Start-Sleep -Milliseconds (250*$attempt)
        }finally{
            if($null -ne $process){try{$process.Dispose()}catch{}}
        }
    }
    if($null -ne $lastError){throw $lastError}
    return @()
}

function Test-FsMonitorTable {
    param([Parameter(Mandatory=$true)][string]$Name)
    $rows=@(Invoke-FsMonitorQuery -Sql ("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name={0}) present;" -f (ConvertTo-FsMonitorSqlLiteral $Name)))
    return ($rows.Count -gt 0 -and [int]$rows[0].present -eq 1)
}

$script:ProjectId=$null
$script:CachedSamples=@()
$script:LastSamplesRead=[DateTime]::MinValue
$script:CachedRunId=0
$script:LastSnapshot=$null
$script:LastMonitorError=''
$script:ObservedRun=$false
$script:MonitorClosing=$false
$script:TuningTablesChecked=$false
$script:TuningTableAvailable=$false
$script:TuningSamplesAvailable=$false

# HF56b: chart telemetry remains available even when Download.AutoTune=false.
# Samples are monitor-local and read-only; they never write to SQLite.
# IMPORTANT for Windows PowerShell 5.1: List[object] created via New-Object
# can throw 'Argument types do not match' when wrapped in @(...). Use the
# .NET constructor and ToArray() explicitly instead.
$script:MonitorLiveSamples=[System.Collections.Generic.List[object]]::new()
$script:MonitorLastTelemetry=$null
$script:MonitorTelemetrySequence=0

function Write-FsMonitorLog {
    param([string]$Message,[System.Management.Automation.ErrorRecord]$ErrorRecord)
    try{
        $detail=$Message
        if($null  -ne $ErrorRecord){
            $detail += "`r`n" + [string]$ErrorRecord.Exception.ToString()
            if(-not[string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)){$detail += "`r`n"+[string]$ErrorRecord.ScriptStackTrace}
        }
        Add-Content -LiteralPath $monitorLog -Encoding UTF8 -Value ("[{0}] {1}`r`n" -f (Get-Date).ToString('o'),$detail)
    }catch{}
}

function Format-MonitorDuration {
    param([Nullable[double]]$Seconds)
    if($null  -eq $Seconds -or $Seconds  -lt 0 -or [double]::IsNaN([double]$Seconds) -or [double]::IsInfinity([double]$Seconds)){ return '--:--'}
    $span=[TimeSpan]::FromSeconds([double]$Seconds)
    if($span.TotalDays  -ge 1){ return $span.ToString('d\.hh\:mm\:ss')}
    if($span.TotalHours  -ge 1){ return $span.ToString('hh\:mm\:ss')}
    return $span.ToString('mm\:ss')
}

function Get-AsciiSparkline {
    param([object[]]$Values,[int]$Width=70)
    $numbers=@($Values |Where-Object{$null  -ne $_}|ForEach-Object{[double]$_}|Where-Object{-not[double]::IsNaN($_) -and -not[double]::IsInfinity($_)})
    if($numbers.Count  -eq 0){ return '(noch keine Messpunkte)'}
    if($numbers.Count  -gt $Width){$numbers=@($numbers |Select-Object -Last $Width)}
    $minimum=($numbers |Measure-Object -Minimum).Minimum;$maximum=($numbers |Measure-Object -Maximum).Maximum
    $chars=' .:-=+*#%@';$builder=New-Object Text.StringBuilder
    foreach($number in $numbers){
        $index=if($maximum -le $minimum){[int][Math]::Floor(($chars.Length-1)/2)}else{[int][Math]::Round((($number-$minimum)/($maximum-$minimum))*($chars.Length-1))}
        $index=[Math]::Max(0,[Math]::Min($chars.Length-1,$index));[void]$builder.Append($chars[$index])
    }
    return $builder.ToString()
}

function Get-FsMonitorTuneStatus {
    param([int]$ProjectId)
    if(-not $script:TuningTablesChecked){
        $script:TuningTableAvailable=Test-FsMonitorTable -Name 'download_tuning'
        $script:TuningSamplesAvailable=Test-FsMonitorTable -Name 'download_tuning_samples'
        $script:TuningTablesChecked=$true
    }
    if(-not $script:TuningTableAvailable){return $null}
    $rows=@(Invoke-FsMonitorQuery -Sql "SELECT * FROM download_tuning WHERE project_id=$ProjectId LIMIT 1;")
    if($rows.Count -eq 0){return $null}
    $row=$rows[0]
    $nowMs=([DateTimeOffset]::UtcNow).ToUnixTimeMilliseconds()
    $started=if($null -eq $row.window_started_at_ms){0}else{[long](Get-FsMonitorScalar $row.window_started_at_ms)}
    $elapsedMs=if($started -gt 0){[Math]::Max([long]1,$nowMs-$started)}else{[long]0}
    $windowFilesPerSecond=if($elapsedMs -gt 0){[double](Get-FsMonitorScalar $row.window_successes)/($elapsedMs/1000.0)}else{0.0}
    $windowBytesPerSecond=if($elapsedMs -gt 0){[double](Get-FsMonitorScalar $row.window_bytes)/($elapsedMs/1000.0)}else{0.0}
    $direction=[int](Get-FsMonitorScalar $row.direction)
    $lastWindowDelay=if($null -eq $row.last_window_delay_ms){$null}else{[int](Get-FsMonitorScalar $row.last_window_delay_ms)}
    $lastWindowFiles=if($null -eq $row.last_window_files_per_second){$null}else{[double](Get-FsMonitorScalar $row.last_window_files_per_second)}
    $lastWindowBytes=if($null -eq $row.last_window_bytes_per_second){$null}else{[double](Get-FsMonitorScalar $row.last_window_bytes_per_second)}
    return [pscustomobject]@{
        Enabled=([int](Get-FsMonitorScalar $row.enabled) -eq 1)
        RunId=$(if($null -eq $row.run_id){0}else{[int](Get-FsMonitorScalar $row.run_id)})
        CurrentDelayMs=[int](Get-FsMonitorScalar $row.current_delay_ms)
        Direction=$direction
        DirectionText=$(if($direction -lt 0){'runter'}elseif($direction -gt 0){'rauf'}else{'halten'})
        DirectionSymbol=$(if($direction -lt 0){'v'}elseif($direction -gt 0){'^'}else{'='})
        StepMs=[int](Get-FsMonitorScalar $row.step_ms)
        WindowTarget=[int](Get-FsMonitorScalar $row.window_target)
        WindowSuccesses=[int](Get-FsMonitorScalar $row.window_successes)
        WindowBytes=[long](Get-FsMonitorScalar $row.window_bytes)
        WindowElapsedMs=$elapsedMs
        WindowFilesPerSecond=$windowFilesPerSecond
        WindowBytesPerSecond=$windowBytesPerSecond
        HasCompletedWindow=($null -ne $lastWindowDelay -and $null -ne $lastWindowFiles)
        LastWindowDelayMs=$lastWindowDelay
        LastWindowSuccesses=$(if($null -eq $row.last_window_successes){0}else{[int](Get-FsMonitorScalar $row.last_window_successes)})
        LastWindowElapsedMs=$(if($null -eq $row.last_window_elapsed_ms){0}else{[long](Get-FsMonitorScalar $row.last_window_elapsed_ms)})
        LastWindowFilesPerSecond=$lastWindowFiles
        LastWindowBytesPerSecond=$lastWindowBytes
        LastWindowAt=[string]$row.last_window_at
        LastDecisionAt=[string]$row.last_decision_at
        BestDelayMs=$(if($null -eq $row.best_delay_ms){$null}else{[int](Get-FsMonitorScalar $row.best_delay_ms)})
        BestFilesPerSecond=$(if($null -eq $row.best_files_per_second){$null}else{[double](Get-FsMonitorScalar $row.best_files_per_second)})
        BestBytesPerSecond=$(if($null -eq $row.best_bytes_per_second){$null}else{[double](Get-FsMonitorScalar $row.best_bytes_per_second)})
        HoldWindows=$(if($null -eq $row.hold_windows){0}else{[int](Get-FsMonitorScalar $row.hold_windows)})
        ThrottleBursts=$(if($null -eq $row.throttle_bursts){0}else{[int](Get-FsMonitorScalar $row.throttle_bursts)})
        BurstOpen=$(if($null -eq $row.burst_open){$false}else{[int](Get-FsMonitorScalar $row.burst_open) -eq 1})
        CooldownUntilMs=$(if($null -eq $row.cooldown_until_ms){0}else{[long](Get-FsMonitorScalar $row.cooldown_until_ms)})
        LastStableDelayMs=$(if($null -eq $row.last_stable_delay_ms){$null}else{[int](Get-FsMonitorScalar $row.last_stable_delay_ms)})
        Total429=$(if($null -eq $row.total_429){0}else{[int](Get-FsMonitorScalar $row.total_429)})
        Last429AtMs=$(if($null -eq $row.last_429_at_ms){0}else{[long](Get-FsMonitorScalar $row.last_429_at_ms)})
        Last429At=[string]$row.last_429_at
        LastChangeReason=[string]$row.last_change_reason
        RunStartTerminal=$(if($null -eq $row.run_start_terminal){0}else{[int](Get-FsMonitorScalar $row.run_start_terminal)})
        RunStartDone=$(if($null -eq $row.run_start_done){0}else{[int](Get-FsMonitorScalar $row.run_start_done)})
        RunStartReused=$(if($null -eq $row.run_start_reused){0}else{[int](Get-FsMonitorScalar $row.run_start_reused)})
        RunStartedAtMs=$(if($null -eq $row.run_started_at_ms){0}else{[long](Get-FsMonitorScalar $row.run_started_at_ms)})
        UpdatedAt=[string]$row.updated_at
    }
}

function Get-FsMonitorDownloadCounts {
    param([int]$ProjectId)
    $counts=[ordered]@{pending=0;running=0;done=0;retryable=0;failed=0;skipped=0;reused=0}
    $rows=@(Invoke-FsMonitorQuery -Sql @"
SELECT CASE WHEN status='failed' AND attempts<4 THEN 'retryable' ELSE status END status,
       COUNT(*) count
FROM project_downloads
WHERE project_id=$ProjectId
GROUP BY CASE WHEN status='failed' AND attempts<4 THEN 'retryable' ELSE status END;
"@)
    foreach($row in $rows){
        $status=[string]$row.status
        if($counts.Contains($status)){$counts[$status]=[int]$row.count}
    }
    return [pscustomobject]$counts
}


function Get-FsMonitorDoneBytes {
    param([int]$ProjectId)
    $rows=@(Invoke-FsMonitorQuery -Sql @"
SELECT COALESCE(SUM(CASE WHEN d.bytes IS NULL THEN 0 ELSE d.bytes END),0) total_bytes
FROM project_downloads pd INDEXED BY ix_project_downloads_queue
JOIN downloads d ON d.media_id=pd.media_id
WHERE pd.project_id=$ProjectId AND pd.status='done';
"@ -ExecutionTimeoutMs 20000)
    if($rows.Count -eq 0){return [long]0}
    return [long](Get-FsMonitorScalar $rows[0].total_bytes)
}

function Get-FsMonitorNetworkBytesReceived {
    $total=[long]0
    try{
        foreach($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
            try{
                if($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up){continue}
                if($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback){continue}
                if($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel){continue}
                $stats=$nic.GetIPv4Statistics()
                $total += [long]$stats.BytesReceived
            }catch{}
        }
    }catch{}
    return $total
}

function Update-FsMonitorRuntimeTelemetry {
    param(
        [int]$RunId,
        [int]$Terminal,
        [int]$Done,
        [int]$Reused,
        [AllowNull()][object]$DoneBytes,
        [AllowNull()][object]$NetworkBytes=$null,
        [int]$DelayMs,
        [DateTime]$At=[DateTime]::UtcNow
    )
    $bytesValue=if($null -eq $DoneBytes){$null}else{[long](Get-FsMonitorScalar $DoneBytes)}
    $networkBytesValue=if($null -eq $NetworkBytes){$null}else{[long](Get-FsMonitorScalar $NetworkBytes)}
    if($null -eq $script:MonitorLastTelemetry){
        $script:MonitorLastTelemetry=[pscustomobject]@{RunId=$RunId;At=$At;Terminal=$Terminal;Done=$Done;Reused=$Reused;DoneBytes=$bytesValue;NetworkBytes=$networkBytesValue}
        return $null
    }
    if([int]$script:MonitorLastTelemetry.RunId -ne $RunId){
        $script:MonitorLiveSamples=[System.Collections.Generic.List[object]]::new()
        $script:MonitorLastTelemetry=[pscustomobject]@{RunId=$RunId;At=$At;Terminal=$Terminal;Done=$Done;Reused=$Reused;DoneBytes=$bytesValue;NetworkBytes=$networkBytesValue}
        return $null
    }
    $elapsed=[Math]::Max(0.001,($At-[DateTime]$script:MonitorLastTelemetry.At).TotalSeconds)
    if($elapsed -lt 1.0){return $null}
    $processedDelta=[Math]::Max(0,$Terminal-[int]$script:MonitorLastTelemetry.Terminal)
    $downloadDelta=[Math]::Max(0,$Done-[int]$script:MonitorLastTelemetry.Done)
    $reusedDelta=[Math]::Max(0,$Reused-[int]$script:MonitorLastTelemetry.Reused)
    $processedRate=[double]$processedDelta/$elapsed
    $downloadRate=[double]$downloadDelta/$elapsed
    $reusedRate=[double]$reusedDelta/$elapsed
    $bytesRate=$null
    if($null -ne $bytesValue -and $null -ne $script:MonitorLastTelemetry.DoneBytes){
        $bytesDelta=[Math]::Max([long]0,$bytesValue-[long]$script:MonitorLastTelemetry.DoneBytes)
        $bytesRate=[double]$bytesDelta/$elapsed
    }
    $networkBytesRate=$null
    if($null -ne $networkBytesValue -and $null -ne $script:MonitorLastTelemetry.NetworkBytes){
        $networkBytesDelta=[Math]::Max([long]0,$networkBytesValue-[long]$script:MonitorLastTelemetry.NetworkBytes)
        $networkBytesRate=[double]$networkBytesDelta/$elapsed
    }
    $script:MonitorTelemetrySequence++
    $sample=[pscustomobject]@{
        id=(1000000000+[int]$script:MonitorTelemetrySequence)
        sample_type='monitor'
        delay_ms=[Math]::Max(0,$DelayMs)
        next_delay_ms=[Math]::Max(0,$DelayMs)
        processed_per_second=$processedRate
        reused_per_second=$reusedRate
        files_per_second=$downloadRate
        bytes_per_second=$bytesRate
        network_bytes_per_second=$networkBytesRate
        status_code=200
        note='read-only Monitorintervall'
        created_at=$At.ToString('o')
    }
    [void]$script:MonitorLiveSamples.Add($sample)
    while($script:MonitorLiveSamples.Count -gt $Samples){$script:MonitorLiveSamples.RemoveAt(0)}
    $script:MonitorLastTelemetry=[pscustomobject]@{RunId=$RunId;At=$At;Terminal=$Terminal;Done=$Done;Reused=$Reused;DoneBytes=$bytesValue;NetworkBytes=$networkBytesValue}
    return $sample
}

function Get-FsMonitorSnapshot {
    try{
        if($null -eq $script:ProjectId){
            $projectRows=@(Invoke-FsMonitorQuery -Sql ("SELECT id FROM projects WHERE name={0} COLLATE NOCASE LIMIT 1;" -f (ConvertTo-FsMonitorSqlLiteral $Project)))
            if($projectRows.Count -eq 0){return $null}
            $script:ProjectId=[int]$projectRows[0].id
        }
        $projectId=[int]$script:ProjectId
        $runRows=@(Invoke-FsMonitorQuery -Sql "SELECT id,status,started_at,finished_at,error FROM runs WHERE project_id=$projectId ORDER BY id DESC LIMIT 1;")
        $run=if($runRows.Count){$runRows[0]}else{$null}
        $runId=if($null -ne $run){[int](Get-FsMonitorScalar $run.id)}else{0}
        if($runId -ne [int]$script:CachedRunId){
            # HF50: Every pipeline run starts with visually empty charts.
            # Historical samples remain in SQLite but are not mixed into the
            # current monitor session.
            $script:CachedRunId=$runId
            $script:CachedSamples=@()
            $script:LastSamplesRead=[DateTime]::MinValue
            $script:MonitorLiveSamples=[System.Collections.Generic.List[object]]::new()
            $script:MonitorLastTelemetry=$null
            $script:MonitorTelemetrySequence=0
        }
        $counts=Get-FsMonitorDownloadCounts -ProjectId $projectId
        $total=[int]$counts.pending+[int]$counts.running+[int]$counts.done+[int]$counts.retryable+[int]$counts.failed+[int]$counts.skipped+[int]$counts.reused
        $successful=[int]$counts.done+[int]$counts.reused
        $terminal=$successful+[int]$counts.failed+[int]$counts.skipped
        $unfinished=[int]$counts.pending+[int]$counts.running+[int]$counts.retryable
        $tune=Get-FsMonitorTuneStatus -ProjectId $projectId

        # HF56: live throughput is measured independently of AutoTune. Reused
        # files count as processed work but contribute no network throughput.
        $doneBytes=$null
        if($runId -gt 0){
            try{$doneBytes=Get-FsMonitorDoneBytes -ProjectId $projectId}catch{}
            $networkBytes=$null
            try{$networkBytes=Get-FsMonitorNetworkBytesReceived}catch{}
            $delayForMonitor=if($null -ne $tune){[int]$tune.CurrentDelayMs}else{0}
            [void](Update-FsMonitorRuntimeTelemetry -RunId $runId -Terminal $terminal -Done ([int]$counts.done) -Reused ([int]$counts.reused) -DoneBytes $doneBytes -NetworkBytes $networkBytes -DelayMs $delayForMonitor -At ([DateTime]::UtcNow))
        }

        if($script:TuningSamplesAvailable -and $runId -gt 0 -and $null -ne $tune -and [bool]$tune.Enabled -and ($script:CachedSamples.Count -eq 0 -or ([DateTime]::UtcNow-$script:LastSamplesRead).TotalSeconds -ge 10)){
            $script:CachedSamples=@(Invoke-FsMonitorQuery -Sql "SELECT * FROM (SELECT id,sample_type,delay_ms,next_delay_ms,files_per_second,bytes_per_second,status_code,note,created_at FROM download_tuning_samples WHERE project_id=$projectId AND run_id=$runId ORDER BY id DESC LIMIT $Samples) ORDER BY id;")
            $script:LastSamplesRead=[DateTime]::UtcNow
        }elseif($runId -le 0){
            $script:CachedSamples=@()
        }

        $sessionProcessed=0;$sessionDone=0;$sessionReused=0
        if($null -ne $tune){
            $sessionProcessed=[Math]::Max(0,$terminal-[int]$tune.RunStartTerminal)
            $sessionDone=[Math]::Max(0,[int]$counts.done-[int]$tune.RunStartDone)
            $sessionReused=[Math]::Max(0,[int]$counts.reused-[int]$tune.RunStartReused)
        }

        $estimateRate=0.0
        if($null -ne $run -and -not[string]::IsNullOrWhiteSpace([string]$run.started_at)){
            try{$runStartedUtc=[DateTimeOffset]::Parse([string]$run.started_at).UtcDateTime}catch{$runStartedUtc=[DateTime]::UtcNow.AddMinutes(-10)}
            $tenMinutesAgo=[DateTime]::UtcNow.AddMinutes(-10)
            $windowStartUtc=if($runStartedUtc -gt $tenMinutesAgo){$runStartedUtc}else{$tenMinutesAgo}
            $elapsedSeconds=[Math]::Max(10.0,[Math]::Min(600.0,([DateTime]::UtcNow-$windowStartUtc).TotalSeconds))
            $windowStartLiteral=ConvertTo-FsMonitorSqlLiteral ($windowStartUtc.ToString('o'))
            $rateRows=@(Invoke-FsMonitorQuery -Sql "SELECT COUNT(*) completed FROM project_downloads WHERE project_id=$projectId AND updated_at >= $windowStartLiteral AND status IN ('done','reused','failed','skipped');")
            if($rateRows.Count -gt 0 -and $elapsedSeconds -gt 0){$estimateRate=[double]$rateRows[0].completed/[double]$elapsedSeconds}
        }
        $remainingSeconds=if($estimateRate -gt 0 -and $unfinished -gt 0){$unfinished/$estimateRate}elseif($unfinished -eq 0){0.0}else{$null}
        $completionText=if($null -ne $remainingSeconds){[DateTime]::Now.AddSeconds([double]$remainingSeconds).ToString('dd.MM.yyyy HH:mm:ss')}else{'--'}
        $percent=if($total -gt 0){[Math]::Round(100.0*$terminal/$total,1)}else{100}
        $sampleList=[System.Collections.Generic.List[object]]::new()
        foreach($row in @($script:CachedSamples)){[void]$sampleList.Add($row)}
        foreach($row in $script:MonitorLiveSamples.ToArray()){[void]$sampleList.Add($row)}
        $latestLive=if($script:MonitorLiveSamples.Count -gt 0){$script:MonitorLiveSamples[$script:MonitorLiveSamples.Count-1]}else{$null}
        $liveProcessedRate=if($null -ne $latestLive){[double]$latestLive.processed_per_second}else{0.0}
        $liveDownloadRate=if($null -ne $latestLive){[double]$latestLive.files_per_second}else{0.0}
        $liveReusedRate=if($null -ne $latestLive -and $null -ne $latestLive.PSObject.Properties['reused_per_second']){[double]$latestLive.reused_per_second}else{0.0}
        $liveBytesRate=if($null -ne $latestLive -and $null -ne $latestLive.bytes_per_second){[double]$latestLive.bytes_per_second}else{0.0}
        $liveNetworkBytesRate=if($null -ne $latestLive -and $null -ne $latestLive.PSObject.Properties['network_bytes_per_second'] -and $null -ne $latestLive.network_bytes_per_second){[double]$latestLive.network_bytes_per_second}else{0.0}
        $snap=[pscustomobject]@{ProjectId=$projectId;Run=$run;Counts=$counts;Tune=$tune;Samples=[object[]]$sampleList.ToArray();Total=$total;Successful=$successful;Terminal=$terminal;Unfinished=$unfinished;Percent=$percent;SessionProcessed=$sessionProcessed;SessionDone=$sessionDone;SessionReused=$sessionReused;EstimateRate=$estimateRate;LiveProcessedRate=$liveProcessedRate;LiveDownloadRate=$liveDownloadRate;LiveReusedRate=$liveReusedRate;LiveBytesPerSecond=$liveBytesRate;LiveNetworkBytesPerSecond=$liveNetworkBytesRate;HasLiveMeasurement=($null -ne $latestLive);RemainingSeconds=$remainingSeconds;CompletionText=$completionText;Warning=''}
        $script:LastSnapshot=$snap;$script:LastMonitorError='';return $snap
    }catch{
        $message=$_.Exception.Message
        if($message -ne $script:LastMonitorError){Write-FsMonitorLog -Message 'Read-only-Monitorabfrage fehlgeschlagen.' -ErrorRecord $_;$script:LastMonitorError=$message}
        if($null -ne $script:LastSnapshot){$script:LastSnapshot.Warning="Letzte Aktualisierung fehlgeschlagen: $message";return $script:LastSnapshot}
        throw
    }
}

function Get-FsMonitorControlText {
    param($Tune)
    if($null -eq $Tune){return 'Anfragesteuerung: noch nicht initialisiert.'}
    $delay=[Math]::Max(0,[int]$Tune.CurrentDelayMs)
    if(-not[bool]$Tune.Enabled){
        return ("Anfrageabstand: {0} ms fest; AutoTune aus. 429-Antworten: {1}; 429-Bursts: {2}." -f $delay,[int]$Tune.Total429,[int]$Tune.ThrottleBursts)
    }
    $remaining=[Math]::Max(0,[int]$Tune.WindowTarget-[int]$Tune.WindowSuccesses)
    $cooldownSeconds=0
    if([long]$Tune.CooldownUntilMs -gt 0){
        $cooldownSeconds=[Math]::Max(0,[int][Math]::Ceiling(([long]$Tune.CooldownUntilMs-[long](([DateTime]::UtcNow-[DateTime]'1970-01-01').TotalMilliseconds))/1000.0))
    }
    if($cooldownSeconds -gt 0){
        $text=("Anfrageabstand: {0} ms. Gemeinsame 429-Pause noch ca. {1} s; danach 3 s gestaffelter Wiederanlauf." -f $delay,$cooldownSeconds)
    }elseif([bool]$Tune.BurstOpen){
        $successesRemaining=[Math]::Max(0,8-[int]$Tune.WindowSuccesses)
        $quietRemaining=if([long]$Tune.Last429AtMs -gt 0){[Math]::Max(0,[int][Math]::Ceiling(60.0-((([DateTimeOffset]::UtcNow).ToUnixTimeMilliseconds()-[long]$Tune.Last429AtMs)/1000.0)))}else{60}
        $text=("Anfrageabstand: {0} ms. Stabilisierung: noch {1} Erfolge und {2} s ohne neue 429; danach wird verkürzt." -f $delay,$successesRemaining,$quietRemaining)
    }elseif($delay -gt 0){
        $decrease=if($delay -le 0){0}else{[Math]::Min(100,[Math]::Max(20,[int][Math]::Ceiling($delay*0.10)))}
        $next=[Math]::Max(0,$delay-$decrease)
        $text=("Anfrageabstand: {0} ms. Messfenster: noch {1} erfolgreiche Dateien; danach entscheidet HF66 anhand des gemessenen Durchsatzes, ob weiter verkürzt oder gehalten wird." -f $delay,$remaining)
    }else{
        $text='Anfrageabstand: 0 ms. Keine zusätzliche künstliche Wartezeit; nur Server-Cooldowns werden beachtet.'
    }
    $text += (" 429-Antworten: {0}; 429-Bursts: {1}." -f [int]$Tune.Total429,[int]$Tune.ThrottleBursts)
    return $text
}

function Show-FsConsoleMonitor {
    while($true){
        try{
            $snap=Get-FsMonitorSnapshot
            Clear-Host
            if($null -eq $snap){
                Write-Host 'FindSeries Download-Monitor' -ForegroundColor Cyan
                Write-Host "Projekt '$Project' wurde noch nicht gefunden. Warte ..." -ForegroundColor DarkYellow
            }else{
                if($null -ne $snap.Run -and [string]$snap.Run.status -eq 'running'){$script:observedRun=$true}
                $tune=$snap.Tune
                $state=if($null -ne $snap.Run -and [string]$snap.Run.status -eq 'running'){'DOWNLOAD LÄUFT'}elseif($snap.Unfinished -eq 0){'DOWNLOAD ABGESCHLOSSEN'}else{'DOWNLOAD PAUSIERT ODER BEENDET'}
                Write-Host ('='*100) -ForegroundColor DarkCyan
                Write-Host (" {0} | {1} | {2}" -f $state,$Project,(Get-Date).ToString('dd.MM.yyyy HH:mm:ss')) -ForegroundColor Cyan
                Write-Host ('='*100) -ForegroundColor DarkCyan
                Write-Host (" Gesamtfortschritt : {0:N0} von {1:N0} Aufgaben erledigt ({2:N1} %); noch {3:N0}." -f $snap.Terminal,$snap.Total,$snap.Percent,$snap.Unfinished)
                Write-Host (" Dieser Lauf        : {0:N0} bearbeitet; {1:N0} neue Downloads; {2:N0} bereits vorhanden; {3} aktiv; {4} Fehler." -f $snap.SessionProcessed,$snap.SessionDone,$snap.SessionReused,$snap.Counts.running,$snap.Counts.failed)
                Write-Host (" Tempo / Prognose   : {0:N2} Dateien/s; Restzeit {1}; voraussichtlich fertig {2}." -f $snap.EstimateRate,(Format-MonitorDuration $snap.RemainingSeconds),$snap.CompletionText)
                Write-Host (" Steuerung          : {0}" -f (Get-FsMonitorControlText $tune)) -ForegroundColor DarkCyan
                if($null -ne $tune){
                    Write-Host (" Messung (nur Info) : aktuelles Fenster {0}/{1}, {2:N2} Dateien/s, {3:N2} MB/s." -f $tune.WindowSuccesses,$tune.WindowTarget,$tune.WindowFilesPerSecond,([double]$tune.WindowBytesPerSecond/1MB)) -ForegroundColor DarkGray
                    if([bool]$tune.HasCompletedWindow){
                        Write-Host (" Letztes Fenster    : {0} ms; {1} Dateien; {2:N2} Dateien/s; {3:N2} MB/s." -f $tune.LastWindowDelayMs,$tune.LastWindowSuccesses,$tune.LastWindowFilesPerSecond,([double]$tune.LastWindowBytesPerSecond/1MB)) -ForegroundColor DarkGray
                    }
                }
                if(-not[string]::IsNullOrWhiteSpace([string]$snap.Warning)){Write-Warning $snap.Warning}

                $delays=@($snap.Samples|ForEach-Object{Get-FsMonitorScalar $_.delay_ms})
                $fps=@($snap.Samples|Where-Object{$null -ne $_.files_per_second}|ForEach-Object{Get-FsMonitorScalar $_.files_per_second})
                $mbps=@($snap.Samples|Where-Object{$null -ne $_.bytes_per_second}|ForEach-Object{([double](Get-FsMonitorScalar $_.bytes_per_second))/1MB})
                Write-Host ''
                Write-Host (" Delay     : {0}" -f (Get-AsciiSparkline $delays)) -ForegroundColor Yellow
                Write-Host (" Dateien/s : {0}" -f (Get-AsciiSparkline $fps)) -ForegroundColor Green
                Write-Host (" MB/s      : {0}" -f (Get-AsciiSparkline $mbps)) -ForegroundColor Cyan
                if($script:observedRun -and ($null -eq $snap.Run -or [string]$snap.Run.status -ne 'running')){return}
            }
        }catch{
            Write-Warning $_.Exception.Message
            Write-FsMonitorLog -Message 'Konsolenmonitor fehlgeschlagen.' -ErrorRecord $_
        }
        if($Once){return}
        Start-Sleep -Seconds $RefreshSeconds
    }
}

function Set-FsDarkChartStyle {
    param($Chart,$Area,$TitleObject)
    $chartBack=[Drawing.Color]::Black
    $axisColor=[Drawing.Color]::Gainsboro
    $gridColor=[Drawing.Color]::FromArgb(70,70,70)
    $Chart.BackColor=$chartBack
    $Area.BackColor=$chartBack
    foreach($axis in @($Area.AxisX,$Area.AxisY)){
        $axis.LabelStyle.ForeColor=$axisColor
        $axis.TitleForeColor=$axisColor
        $axis.LineColor=$axisColor
        $axis.MajorTickMark.LineColor=$axisColor
        $axis.MinorTickMark.LineColor=$axisColor
        $axis.MajorGrid.LineColor=$gridColor
        $axis.MinorGrid.LineColor=$gridColor
    }
    if($null -ne $TitleObject){$TitleObject.ForeColor=$axisColor}
}

function New-FsMonitorChart {
    param([string]$Title,[string]$YAxisTitle,[string]$YAxisFormat='0.00')
    $chart=New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock='Fill'
    $area=New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.Name='main'
    $area.AxisX.LabelStyle.Format='HH:mm'
    $area.AxisX.Title='Zeit'
    $area.AxisX.MajorGrid.LineDashStyle='Dot'
    $area.AxisY.Title=$YAxisTitle
    $area.AxisY.LabelStyle.Format=$YAxisFormat
    $area.AxisY.MajorGrid.LineDashStyle='Dot'
    [void]$chart.ChartAreas.Add($area)
    $series=New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.Name='value'
    $series.ChartType='Line'
    $series.BorderWidth=2
    $series.Color=[Drawing.Color]::DeepSkyBlue
    $series.MarkerColor=[Drawing.Color]::DeepSkyBlue
    $series.MarkerStyle='Circle'
    $series.MarkerSize=4
    $series.XValueType=[System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
    [void]$chart.Series.Add($series)
    $titleObject=New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $titleObject.Text=$Title
    [void]$chart.Titles.Add($titleObject)
    Set-FsDarkChartStyle -Chart $chart -Area $area -TitleObject $titleObject
    return $chart
}

function Set-FsChartPoints {
    param($Chart,[object[]]$Rows,[scriptblock]$ValueSelector)
    $series=$Chart.Series[0]
    $series.Points.Clear()
    foreach($row in @($Rows)){
        $value=Get-FsMonitorScalar (& $ValueSelector $row)
        if($null -eq $value){continue}
        $number=[double](Get-FsMonitorScalar $value)
        if([double]::IsNaN($number) -or [double]::IsInfinity($number)){continue}
        try{$at=[DateTimeOffset]::Parse([string](Get-FsMonitorScalar $row.created_at)).LocalDateTime}catch{$at=Get-Date}

        # Avoid the ambiguous AddXY(params double[]) overload in Windows
        # PowerShell 5.1. Assign an explicit double[] to a DataPoint instead.
        $point=New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $point.XValue=[double]$at.ToOADate()
        $point.YValues=[double[]]@($number)
        [void]$series.Points.Add($point)
    }
}

function New-FsScatterChart {
    param([string]$Title,[string]$YAxisTitle,[string]$XAxisTitle='Delay (ms)',[string]$XAxisFormat='0',[string]$YAxisFormat='0.0')
    $chart=New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock='Fill'
    $area=New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.Name='main'
    $area.AxisX.Title=$XAxisTitle
    $area.AxisX.LabelStyle.Format=$XAxisFormat
    $area.AxisX.IsStartedFromZero=$false
    $area.AxisX.MajorGrid.LineDashStyle='Dot'
    $area.AxisY.Title=$YAxisTitle
    $area.AxisY.LabelStyle.Format=$YAxisFormat
    $area.AxisY.MajorGrid.LineDashStyle='Dot'
    [void]$chart.ChartAreas.Add($area)
    $series=New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.Name='points'
    $series.ChartType='Point'
    $series.MarkerStyle='Circle'
    $series.MarkerSize=8
    [void]$chart.Series.Add($series)
    $titleObject=New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $titleObject.Text=$Title
    [void]$chart.Titles.Add($titleObject)
    Set-FsDarkChartStyle -Chart $chart -Area $area -TitleObject $titleObject
    return $chart
}

function Get-FsFalseColor {
    param([double]$Fraction)
    $f=[Math]::Max(0.0,[Math]::Min(1.0,$Fraction));$palette=@([Drawing.Color]::FromArgb(0,70,255),[Drawing.Color]::FromArgb(0,200,255),[Drawing.Color]::FromArgb(0,190,80),[Drawing.Color]::FromArgb(255,210,0),[Drawing.Color]::FromArgb(230,40,20))
    $scaled=$f*($palette.Count-1);$left=[int][Math]::Floor($scaled);$right=[Math]::Min($palette.Count-1,$left+1);$mix=$scaled-$left
    return [Drawing.Color]::FromArgb([int][Math]::Round($palette[$left].R+($palette[$right].R-$palette[$left].R)*$mix),[int][Math]::Round($palette[$left].G+($palette[$right].G-$palette[$left].G)*$mix),[int][Math]::Round($palette[$left].B+($palette[$right].B-$palette[$left].B)*$mix))
}


function Select-FsScatterRows {
    param([object[]]$Rows,[int]$Maximum=240,[int]$LiveSpacingSeconds=300)
    $selected=[System.Collections.Generic.List[object]]::new()
    $lastLiveAt=[DateTime]::MinValue
    $lastLiveDelay=$null
    foreach($row in @($Rows)){
        $sampleType=[string](Get-FsMonitorScalar $row.sample_type)
        if($sampleType -in @('window','recovery','live_current','monitor')){
            [void]$selected.Add($row)
            continue
        }
        if($sampleType -ne 'live'){continue}
        try{$at=[DateTimeOffset]::Parse([string](Get-FsMonitorScalar $row.created_at)).UtcDateTime}catch{$at=[DateTime]::UtcNow}
        $delay=[int](Get-FsMonitorScalar $row.delay_ms)
        $delayChanged=($null -eq $lastLiveDelay -or $delay -ne [int]$lastLiveDelay)
        if($delayChanged -or $lastLiveAt -eq [DateTime]::MinValue -or ($at-$lastLiveAt).TotalSeconds -ge $LiveSpacingSeconds){
            [void]$selected.Add($row)
            $lastLiveAt=$at
            $lastLiveDelay=$delay
        }
    }
    if($selected.Count -le $Maximum){return @($selected.ToArray())}

    # Keep the complete chronology but cap WinForms series count. Always retain
    # first and last point; completed windows/recovery decisions are kept when possible.
    $result=[System.Collections.Generic.List[object]]::new()
    $step=[Math]::Max(1,[int][Math]::Ceiling($selected.Count/[double]$Maximum))
    for($i=0;$i -lt $selected.Count;$i++){
        $type=[string](Get-FsMonitorScalar $selected[$i].sample_type)
        if($i -eq 0 -or $i -eq ($selected.Count-1) -or $type -in @('window','recovery','live_current') -or ($i % $step) -eq 0){
            [void]$result.Add($selected[$i])
        }
    }
    return @($result.ToArray() | Select-Object -First $Maximum)
}

function Set-FsScatterPoints {
    param($Chart,[object[]]$Rows,[scriptblock]$ValueSelector,[string]$Unit)
    while($Chart.Series.Count -gt 1){$Chart.Series.RemoveAt($Chart.Series.Count-1)}
    $series=$Chart.Series[0]
    $series.Points.Clear()
    $usable=[System.Collections.Generic.List[object]]::new()
    foreach($row in @($Rows)){
        $value=Get-FsMonitorScalar (& $ValueSelector $row)
        if($null -eq $value){continue}
        $number=[double](Get-FsMonitorScalar $value)
        if([double]::IsNaN($number) -or [double]::IsInfinity($number)){continue}
        $delay=[double](Get-FsMonitorScalar $row.delay_ms)
        if([double]::IsNaN($delay) -or [double]::IsInfinity($delay)){continue}
        $sampleType=[string](Get-FsMonitorScalar $row.sample_type)
        $usable.Add([pscustomobject]@{Row=$row;Value=$number;Delay=$delay;SampleType=$sampleType})
    }
    $denominator=[Math]::Max(1,$usable.Count-1)

    # Chronological line segments retain exact measured coordinates. Marker
    # positions are jittered separately below.
    for($index=1;$index -lt $usable.Count;$index++){
        $previous=$usable[$index-1]
        $current=$usable[$index]
        $fraction=$index/[double]$denominator
        $segment=New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $segment.Name=("time_segment_{0}" -f $index)
        $segment.ChartType='Line'
        $segment.BorderWidth=2
        $segmentBaseColor=Get-FsFalseColor $fraction
        $segment.Color=[Drawing.Color]::FromArgb(105,$segmentBaseColor.R,$segmentBaseColor.G,$segmentBaseColor.B)
        $segment.IsVisibleInLegend=$false
        foreach($entry in @($previous,$current)){
            $segmentPoint=New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
            $segmentPoint.XValue=[double]$entry.Delay
            $segmentPoint.YValues=[double[]]@([double]$entry.Value)
            [void]$segment.Points.Add($segmentPoint)
        }
        [void]$Chart.Series.Add($segment)
    }

    $delayValues=@($usable | ForEach-Object {[double]$_.Delay})
    $metricValues=@($usable | ForEach-Object {[double]$_.Value})
    $delayMin=if($delayValues.Count){[double]($delayValues|Measure-Object -Minimum).Minimum}else{0.0}
    $delayMax=if($delayValues.Count){[double]($delayValues|Measure-Object -Maximum).Maximum}else{1.0}
    $delaySpan=[Math]::Max(1.0,$delayMax-$delayMin)
    $metricMin=if($metricValues.Count){[double]($metricValues|Measure-Object -Minimum).Minimum}else{0.0}
    $metricMax=if($metricValues.Count){[double]($metricValues|Measure-Object -Maximum).Maximum}else{1.0}
    $metricSpan=[Math]::Max(0.001,$metricMax-$metricMin)
    $xStep=[Math]::Max(0.20,$delaySpan/300.0)
    $yStep=[Math]::Max(0.0005,$metricSpan/180.0)

    $groupCounts=@{}
    foreach($entry in $usable){
        $key=([double]$entry.Delay).ToString('R',[Globalization.CultureInfo]::InvariantCulture)
        if(-not $groupCounts.ContainsKey($key)){$groupCounts[$key]=0}
        $groupCounts[$key]=[int]$groupCounts[$key]+1
    }
    $groupIndexes=@{}

    for($index=0;$index -lt $usable.Count;$index++){
        $entry=$usable[$index]
        $key=([double]$entry.Delay).ToString('R',[Globalization.CultureInfo]::InvariantCulture)
        if(-not $groupIndexes.ContainsKey($key)){$groupIndexes[$key]=0}
        $duplicateIndex=[int]$groupIndexes[$key]
        $groupIndexes[$key]=$duplicateIndex+1
        $duplicateCount=[int]$groupCounts[$key]

        # Nine-column beeswarm. Even dozens of measurements at Delay=0 remain
        # individually selectable without falsifying the line or tooltip values.
        $rawColumn=($duplicateIndex % 9)-4
        $rowBand=[int][Math]::Floor($duplicateIndex/9)
        $rowSign=if(($rowBand % 2) -eq 0){1}else{-1}

        # Around Delay 0 a symmetric jitter would reflect negative marker
        # coordinates onto positive ones and make pairs overlap. Use nine
        # one-sided columns at the left axis instead; for all other delays keep
        # the centered beeswarm. This changes display coordinates only.
        $column=if([double]$entry.Delay -le ($xStep*4)){($duplicateIndex % 9)}else{$rawColumn}
        $displayX=[double]$entry.Delay+($column*$xStep)
        $displayY=[double]$entry.Value+($rowSign*[Math]::Ceiling(($rowBand+1)/2.0)*$yStep)

        $point=New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $point.XValue=$displayX
        $point.YValues=[double[]]@($displayY)
        $falseColor=Get-FsFalseColor ($index/[double]$denominator)
        $isCurrent=([string]$entry.SampleType -eq 'live_current')
        $isLive=([string]$entry.SampleType -eq 'live')
        if($isCurrent -or $isLive){
            $point.Color=[Drawing.Color]::Black
            $point.MarkerBorderColor=$falseColor
            $point.MarkerBorderWidth=2
            $point.MarkerSize=$(if($isCurrent){10}else{7})
        }else{
            $point.Color=$falseColor
            $point.MarkerBorderColor=[Drawing.Color]::White
            $point.MarkerBorderWidth=1
            $point.MarkerSize=8
        }
        try{$at=[DateTimeOffset]::Parse([string](Get-FsMonitorScalar $entry.Row.created_at)).LocalDateTime.ToString('dd.MM. HH:mm:ss')}catch{$at='--'}
        $kind=if($isCurrent){'laufendes Teilfenster'}elseif($isLive){'periodischer Messpunkt'}else{'abgeschlossenes Messfenster'}
        $point.ToolTip=("Messung {0}/{1} ({2})`n{3}`nEchter Delay {4} ms`n{5:N3} {6}" -f ($index+1),$usable.Count,$kind,$at,[int]$entry.Delay,[double]$entry.Value,$Unit)
        [void]$series.Points.Add($point)
    }

    if($usable.Count -gt 0){
        $padding=[Math]::Max(2.0,$delaySpan*0.04)
        $Chart.ChartAreas[0].AxisX.Minimum=[Math]::Max(0.0,$delayMin-$padding)
        $Chart.ChartAreas[0].AxisX.Maximum=$delayMax+$padding
        if($delayMax -eq $delayMin){
            $Chart.ChartAreas[0].AxisX.Minimum=[Math]::Max(0.0,$delayMin-5.0)
            $Chart.ChartAreas[0].AxisX.Maximum=$delayMax+5.0
        }
        $visibleSpan=[Math]::Max(1.0,[double]$Chart.ChartAreas[0].AxisX.Maximum-[double]$Chart.ChartAreas[0].AxisX.Minimum)
        $Chart.ChartAreas[0].AxisX.Interval=$(if($visibleSpan -le 10){1}elseif($visibleSpan -le 25){5}elseif($visibleSpan -le 100){20}elseif($visibleSpan -le 500){100}elseif($visibleSpan -le 1000){200}else{500})
    }
}


function Set-FsXYScatterPoints {
    param(
        $Chart,
        [object[]]$Rows,
        [scriptblock]$XSelector,
        [scriptblock]$YSelector,
        [string]$XUnit,
        [string]$YUnit
    )
    while($Chart.Series.Count -gt 1){$Chart.Series.RemoveAt($Chart.Series.Count-1)}
    $series=$Chart.Series[0]
    $series.Points.Clear()
    $usable=[System.Collections.Generic.List[object]]::new()
    foreach($row in @($Rows)){
        $xRaw=Get-FsMonitorScalar (& $XSelector $row)
        $yRaw=Get-FsMonitorScalar (& $YSelector $row)
        if($null -eq $xRaw -or $null -eq $yRaw){continue}
        $x=[double](Get-FsMonitorScalar $xRaw)
        $y=[double](Get-FsMonitorScalar $yRaw)
        if([double]::IsNaN($x) -or [double]::IsInfinity($x) -or [double]::IsNaN($y) -or [double]::IsInfinity($y)){continue}
        [void]$usable.Add([pscustomobject]@{Row=$row;X=$x;Y=$y})
    }
    $denominator=[Math]::Max(1,$usable.Count-1)

    # Chronological trail: each segment uses the color of the later point,
    # but with reduced alpha so markers stay visually dominant.
    for($index=1;$index -lt $usable.Count;$index++){
        $previous=$usable[$index-1]
        $current=$usable[$index]
        $fraction=$index/[double]$denominator
        $segmentBaseColor=Get-FsFalseColor $fraction
        $segment=New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $segment.Name=("xy_time_segment_{0}" -f $index)
        $segment.ChartType='Line'
        $segment.BorderWidth=2
        $segment.Color=[Drawing.Color]::FromArgb(105,$segmentBaseColor.R,$segmentBaseColor.G,$segmentBaseColor.B)
        $segment.IsVisibleInLegend=$false
        foreach($entry in @($previous,$current)){
            $segmentPoint=New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
            $segmentPoint.XValue=[double]$entry.X
            $segmentPoint.YValues=[double[]]@([double]$entry.Y)
            [void]$segment.Points.Add($segmentPoint)
        }
        [void]$Chart.Series.Add($segment)
    }

    for($index=0;$index -lt $usable.Count;$index++){
        $entry=$usable[$index]
        $point=New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $point.XValue=[double]$entry.X
        $point.YValues=[double[]]@([double]$entry.Y)
        $point.Color=Get-FsFalseColor ($index/[double]$denominator)
        $point.MarkerBorderColor=[Drawing.Color]::White
        $point.MarkerBorderWidth=1
        $point.MarkerSize=8
        try{$at=[DateTimeOffset]::Parse([string](Get-FsMonitorScalar $entry.Row.created_at)).LocalDateTime.ToString('dd.MM. HH:mm:ss')}catch{$at='--'}
        $point.ToolTip=("Messung {0}/{1}`n{2}`nX: {3:N3} {4}`nY: {5:N3} {6}" -f ($index+1),$usable.Count,$at,[double]$entry.X,$XUnit,[double]$entry.Y,$YUnit)
        [void]$series.Points.Add($point)
    }
    if($usable.Count -gt 0){
        $xValues=@($usable | ForEach-Object {[double]$_.X})
        $yValues=@($usable | ForEach-Object {[double]$_.Y})
        $xMin=[double]($xValues|Measure-Object -Minimum).Minimum
        $xMax=[double]($xValues|Measure-Object -Maximum).Maximum
        $yMin=[double]($yValues|Measure-Object -Minimum).Minimum
        $yMax=[double]($yValues|Measure-Object -Maximum).Maximum
        $xSpan=[Math]::Max(0.01,$xMax-$xMin)
        $ySpan=[Math]::Max(0.01,$yMax-$yMin)
        $xPad=[Math]::Max(0.01,$xSpan*0.08)
        $yPad=[Math]::Max(0.01,$ySpan*0.08)
        $Chart.ChartAreas[0].AxisX.Minimum=[Math]::Max(0.0,$xMin-$xPad)
        $Chart.ChartAreas[0].AxisX.Maximum=$xMax+$xPad
        $Chart.ChartAreas[0].AxisY.Minimum=[Math]::Max(0.0,$yMin-$yPad)
        $Chart.ChartAreas[0].AxisY.Maximum=$yMax+$yPad
    }
}

function Hide-FsMonitorConsoleWindow {
    if(-not $HideConsole){return}
    try{
        if(-not ('FindSeries.MonitorNativeWindow' -as [type])){
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FindSeries {
    public static class MonitorNativeWindow {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}
'@
        }
        $consoleHandle=[FindSeries.MonitorNativeWindow]::GetConsoleWindow()
        if($consoleHandle -ne [IntPtr]::Zero){
            [void][FindSeries.MonitorNativeWindow]::ShowWindow($consoleHandle,0)
        }
    }catch{
        Write-FsMonitorLog -Message 'Konsolenfenster konnte nicht ausgeblendet werden.' -ErrorRecord $_
    }
}

function Write-FsMonitorReadyMarker {
    if([string]::IsNullOrWhiteSpace($ReadyFile)){return}
    try{
        $parent=Split-Path -Parent $ReadyFile
        if(-not[string]::IsNullOrWhiteSpace($parent) -and -not(Test-Path -LiteralPath $parent)){
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $ReadyFile -Encoding UTF8 -Value (
            "pid={0}`r`nstarted={1}`r`nproject={2}" -f $PID,(Get-Date).ToString('o'),$Project
        )
    }catch{
        Write-FsMonitorLog -Message 'Bereitschaftsmarker konnte nicht geschrieben werden.' -ErrorRecord $_
    }
}

function Show-FsGuiMonitor {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization

    $form=New-Object System.Windows.Forms.Form
    $form.Text="FindSeries Download-Monitor – $Project [HF66]"
    $form.Width=1500
    $form.Height=1120
    $form.StartPosition='CenterScreen'
    $form.BackColor=[Drawing.Color]::Black

    function New-FsMonitorRowPanel {
        param([int]$Columns)
        $row=New-Object System.Windows.Forms.TableLayoutPanel
        $row.Dock='Fill'
        $row.BackColor=[Drawing.Color]::Black
        $row.ColumnCount=$Columns
        $row.RowCount=1
        [void]$row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),100))
        $columnWidth=100.0/[double]$Columns
        for($columnIndex=0;$columnIndex -lt $Columns;$columnIndex++){
            [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),$columnWidth))
        }
        return $row
    }

    $layout=New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill'
    $layout.BackColor=[Drawing.Color]::Black
    $layout.ColumnCount=1
    $layout.RowCount=5
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),100))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute),155))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),25))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),25))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),25))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),25))

    $summary=New-Object System.Windows.Forms.TextBox
    $summary.Dock='Fill'
    $summary.Font=New-Object System.Drawing.Font -ArgumentList 'Consolas',10
    $summary.Multiline=$true
    $summary.ReadOnly=$true
    $summary.WordWrap=$false
    $summary.ScrollBars='None'
    $summary.BorderStyle='None'
    $summary.BackColor=[Drawing.Color]::Black
    $summary.ForeColor=[Drawing.Color]::Gainsboro
    $summary.Margin=New-Object System.Windows.Forms.Padding -ArgumentList 10
    [void]$layout.Controls.Add($summary,0,0)

    $row1=New-FsMonitorRowPanel -Columns 3
    $row2=New-FsMonitorRowPanel -Columns 2
    $row3=New-FsMonitorRowPanel -Columns 2
    $row4=New-FsMonitorRowPanel -Columns 2

    # Row 1: request spacing, overall work rate, real new-download rate.
    $delayChart=New-FsMonitorChart -Title 'Anfrageabstand über die Zeit' -YAxisTitle 'Abstand (ms)' -YAxisFormat '0'
    $processedChart=New-FsMonitorChart -Title 'Verarbeitete Aufgaben pro Sekunde' -YAxisTitle 'Aufgaben/s' -YAxisFormat '0.00'
    $filesChart=New-FsMonitorChart -Title 'Neue Downloads pro Sekunde' -YAxisTitle 'Downloads/s' -YAxisFormat '0.00'

    # Row 2: FindSeries download throughput and total system receive throughput.
    $downloadBytesChart=New-FsMonitorChart -Title 'Downloads MB/s über die Zeit' -YAxisTitle 'MB/s' -YAxisFormat '0.0'
    $networkChart=New-FsMonitorChart -Title 'Netzwerkdurchsatz über die Zeit (System)' -YAxisTitle 'MB/s' -YAxisFormat '0.0'

    # Row 3: throughput relation to tasks/download count.
    $processedBytesScatter=New-FsScatterChart -Title 'MB/s vs. Aufgaben/s – blau früh, rot spät' -YAxisTitle 'MB/s' -XAxisTitle 'Aufgaben/s' -XAxisFormat '0.00' -YAxisFormat '0.0'
    $downloadsBytesScatter=New-FsScatterChart -Title 'MB/s vs. neue Downloads/s – blau früh, rot spät' -YAxisTitle 'MB/s' -XAxisTitle 'Downloads/s' -XAxisFormat '0.00' -YAxisFormat '0.0'

    # Row 4: keep the legacy dynamic-delay scatters.
    $filesScatter=New-FsScatterChart -Title 'Downloads/s vs. Delay – blau früh, rot spät' -YAxisTitle 'Downloads/s' -XAxisTitle 'Delay (ms)' -XAxisFormat '0' -YAxisFormat '0.00'
    $bytesScatter=New-FsScatterChart -Title 'MB/s vs. Delay – blau früh, rot spät' -YAxisTitle 'MB/s' -XAxisTitle 'Delay (ms)' -XAxisFormat '0' -YAxisFormat '0.0'

    [void]$row1.Controls.Add($delayChart,0,0)
    [void]$row1.Controls.Add($processedChart,1,0)
    [void]$row1.Controls.Add($filesChart,2,0)
    [void]$row2.Controls.Add($downloadBytesChart,0,0)
    [void]$row2.Controls.Add($networkChart,1,0)
    [void]$row3.Controls.Add($processedBytesScatter,0,0)
    [void]$row3.Controls.Add($downloadsBytesScatter,1,0)
    [void]$row4.Controls.Add($filesScatter,0,0)
    [void]$row4.Controls.Add($bytesScatter,1,0)

    [void]$layout.Controls.Add($row1,0,1)
    [void]$layout.Controls.Add($row2,0,2)
    [void]$layout.Controls.Add($row3,0,3)
    [void]$layout.Controls.Add($row4,0,4)
    [void]$form.Controls.Add($layout)

    $timer=New-Object System.Windows.Forms.Timer
    $timer.Interval=[Math]::Max(2000,$RefreshSeconds*1000)

    $updateAction={
        if($script:MonitorClosing -or $form.IsDisposed -or $form.Disposing){return}
        try{
            $snap=Get-FsMonitorSnapshot
            if($null -eq $snap){
                $summary.Text="Projekt '$Project' wurde noch nicht gefunden. Warte ..."
                return
            }
            if($null -ne $snap.Run -and [string]$snap.Run.status -eq 'running'){$script:observedRun=$true}
            $tune=$snap.Tune
            $state=if($null -ne $snap.Run -and [string]$snap.Run.status -eq 'running'){'DOWNLOAD LÄUFT'}elseif($snap.Unfinished -eq 0){'DOWNLOAD ABGESCHLOSSEN'}else{'DOWNLOAD PAUSIERT ODER BEENDET'}
            $measurement=if([bool]$snap.HasLiveMeasurement){
                ("Aktuelles Monitorintervall: {0:N2} Aufgaben/s; davon {1:N2} reused/s und {2:N2} neue Downloads/s; {3:N2} MB/s Downloads; {4:N2} MB/s System-Netzwerk." -f $snap.LiveProcessedRate,$snap.LiveReusedRate,$snap.LiveDownloadRate,([double]$snap.LiveBytesPerSecond/1MB),([double]$snap.LiveNetworkBytesPerSecond/1MB))
            }else{
                'Aktuelles Monitorintervall: Baseline erfasst; erster Durchsatzpunkt folgt nach dem nächsten Refresh.'
            }
            if($null -ne $tune -and [bool]$tune.Enabled -and [bool]$tune.HasCompletedWindow){
                $measurement += (" Letztes AutoTune-Fenster: {0} ms, {1:N2} Downloads/s, {2:N2} MB/s." -f $tune.LastWindowDelayMs,$tune.LastWindowFilesPerSecond,([double]$tune.LastWindowBytesPerSecond/1MB))
            }
            $warningText=if([string]::IsNullOrWhiteSpace([string]$snap.Warning)){''}else{"`r`nHinweis: $($snap.Warning)"}
            $summary.Text=(
                "$state`r`n"+
                ("Gesamt: {0:N0} von {1:N0} Dateien verarbeitet ({2:N1} %); noch {3:N0}.`r`n" -f $snap.Terminal,$snap.Total,$snap.Percent,$snap.Unfinished)+
                ("Dieser Lauf: {0:N0} verarbeitet; {1:N0} neu heruntergeladen; {2:N0} bereits vorhanden; {3} aktiv; {4} Fehler.`r`n" -f $snap.SessionProcessed,$snap.SessionDone,$snap.SessionReused,$snap.Counts.running,$snap.Counts.failed)+
                ("Tempo (10-Min.-Mittel): {0:N2} Aufgaben/s; Restzeit: {1}; voraussichtlich fertig: {2}.`r`n" -f $snap.EstimateRate,(Format-MonitorDuration $snap.RemainingSeconds),$snap.CompletionText)+
                (Get-FsMonitorControlText $tune)+"`r`n"+
                $measurement+
                $warningText
            )

            $monitorRows=@($snap.Samples|Where-Object{$_.sample_type -eq 'monitor'})
            $delayRows=if($monitorRows.Count -gt 0){$monitorRows}else{@($snap.Samples|Where-Object{$_.sample_type -in @('live','window','throttle','recovery')})}
            $throughputRows=if($monitorRows.Count -gt 0){$monitorRows}else{@($snap.Samples|Where-Object{$_.sample_type -in @('live','window','recovery')})}
            $scatterRows=@(Select-FsScatterRows -Rows @($throughputRows) -Maximum 240 -LiveSpacingSeconds 0)
            $chartErrors=[System.Collections.Generic.List[string]]::new()
            foreach($chartAction in @(
                {Set-FsChartPoints $delayChart $delayRows {param($r)$r.delay_ms}},
                {Set-FsChartPoints $processedChart $monitorRows {param($r)if($null -eq $r.PSObject.Properties['processed_per_second']){return $null};$r.processed_per_second}},
                {Set-FsChartPoints $filesChart $throughputRows {param($r)$r.files_per_second}},
                {Set-FsChartPoints $downloadBytesChart $throughputRows {param($r)if($null -eq $r.bytes_per_second){return $null};([double](Get-FsMonitorScalar $r.bytes_per_second))/1MB}},
                {Set-FsChartPoints $networkChart $monitorRows {param($r)if($null -eq $r.PSObject.Properties['network_bytes_per_second'] -or $null -eq $r.network_bytes_per_second){return $null};([double](Get-FsMonitorScalar $r.network_bytes_per_second))/1MB}},
                {Set-FsXYScatterPoints $processedBytesScatter $scatterRows {param($r)if($null -eq $r.PSObject.Properties['processed_per_second']){return $null};$r.processed_per_second} {param($r)if($null -eq $r.bytes_per_second){return $null};([double](Get-FsMonitorScalar $r.bytes_per_second))/1MB} 'Aufgaben/s' 'MB/s'},
                {Set-FsXYScatterPoints $downloadsBytesScatter $scatterRows {param($r)$r.files_per_second} {param($r)if($null -eq $r.bytes_per_second){return $null};([double](Get-FsMonitorScalar $r.bytes_per_second))/1MB} 'Downloads/s' 'MB/s'},
                {Set-FsScatterPoints $filesScatter $scatterRows {param($r)$r.files_per_second} 'Downloads/s'},
                {Set-FsScatterPoints $bytesScatter $scatterRows {param($r)if($null -eq $r.bytes_per_second){return $null};([double](Get-FsMonitorScalar $r.bytes_per_second))/1MB} 'MB/s'}
            )){
                try{&$chartAction}catch{$chartErrors.Add($_.Exception.Message)}
            }
            if($chartErrors.Count -gt 0){
                $chartMessage=($chartErrors|Select-Object -Unique)-join ' | '
                $summary.AppendText("`r`nChartwarnung: $chartMessage")
                Write-FsMonitorLog -Message ("Chartaktualisierung: "+$chartMessage)
            }
            if($script:observedRun -and ($null -eq $snap.Run -or [string]$snap.Run.status -ne 'running')){
                $timer.Stop()
                $form.Text='FindSeries Download-Monitor – Lauf beendet [HF66]'
            }
        }catch [System.Management.Automation.PipelineStoppedException]{
            if(-not $script:MonitorClosing){throw}
        }catch{
            if($script:MonitorClosing){return}
            $message="Monitorfehler: $($_.Exception.Message)`r`nDetails: $monitorLog"
            $summary.Text=$message
            Write-FsMonitorLog -Message 'GUI-Monitor fehlgeschlagen.' -ErrorRecord $_
        }
    }
    $timer.Add_Tick($updateAction)
    $form.Add_Shown({
        try{
            $form.WindowState=[System.Windows.Forms.FormWindowState]::Normal
            $form.ShowInTaskbar=$true
            $form.Activate()
            $form.BringToFront()
            Write-FsMonitorReadyMarker
            Hide-FsMonitorConsoleWindow
        }catch{
            Write-FsMonitorLog -Message 'Monitorfenster konnte nicht sichtbar bestätigt werden.' -ErrorRecord $_
        }
        &$updateAction
        $timer.Start()
    })
    # Stop the PowerShell-backed WinForms timer before ShowDialog returns.
    # Otherwise a queued Tick can run while the hosting PowerShell pipeline is
    # already being torn down and surface as an unhandled PipelineStoppedException.
    $form.Add_FormClosing({
        $script:MonitorClosing=$true
        try{$timer.Stop()}catch{}
        try{$timer.Remove_Tick($updateAction)}catch{}
    })
    $form.Add_FormClosed({
        $script:MonitorClosing=$true
        try{$timer.Stop()}catch{}
        try{$timer.Remove_Tick($updateAction)}catch{}
        try{$timer.Dispose()}catch{}
        if(-not[string]::IsNullOrWhiteSpace($ReadyFile)){
            Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
        }
    })
    [void]$form.ShowDialog()
}

try{
    if($SelfTest){
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization
        $projectRows=@(Invoke-FsMonitorQuery -Sql ("SELECT id FROM projects WHERE name={0} COLLATE NOCASE LIMIT 1;" -f (ConvertTo-FsMonitorSqlLiteral $Project)))
        if($projectRows.Count -ne 1){throw "Monitor-Selbsttestprojekt '$Project' wurde nicht eindeutig gefunden."}
        $projectId=[int](Get-FsMonitorScalar $projectRows[0].id)
        $script:MonitorLiveSamples=[System.Collections.Generic.List[object]]::new()
        $script:MonitorLastTelemetry=$null
        $script:MonitorTelemetrySequence=0
        $baselineAt=[DateTime]::Parse('2026-08-09T06:00:00Z').ToUniversalTime()
        $firstRuntime=Update-FsMonitorRuntimeTelemetry -RunId 999 -Terminal 100 -Done 10 -DoneBytes ([long](10MB)) -DelayMs 1370 -At $baselineAt
        if($null -ne $firstRuntime){throw 'HF66-Monitor erzeugt bereits für die Baseline einen falschen Messpunkt.'}
        $secondRuntime=Update-FsMonitorRuntimeTelemetry -RunId 999 -Terminal 120 -Done 15 -DoneBytes ([long](20MB)) -DelayMs 1370 -At $baselineAt.AddSeconds(10)
        if($null -eq $secondRuntime -or [Math]::Abs([double]$secondRuntime.processed_per_second-2.0) -gt 0.001 -or [Math]::Abs([double]$secondRuntime.files_per_second-0.5) -gt 0.001 -or [Math]::Abs(([double]$secondRuntime.bytes_per_second/1MB)-1.0) -gt 0.001){throw 'HF66-Monitor berechnet read-only Laufzeitdurchsatz nicht korrekt.'}
        $disabledTune=[pscustomobject]@{Enabled=$false;CurrentDelayMs=1370;WindowTarget=100;WindowSuccesses=0;CooldownUntilMs=0;BurstOpen=$false;Total429=0;ThrottleBursts=0;Last429AtMs=0}
        if((Get-FsMonitorControlText $disabledTune) -notmatch 'AutoTune aus'){throw 'HF66-Monitor beschreibt deaktiviertes AutoTune weiterhin fälschlich als automatische Delay-Absenkung.'}
        $sampleRows=@(Invoke-FsMonitorQuery -Sql "SELECT id,sample_type,delay_ms,files_per_second,bytes_per_second,created_at FROM download_tuning_samples WHERE project_id=$projectId ORDER BY id;")
        if($sampleRows.Count -lt 2){throw 'Monitor-Selbsttest benötigt mindestens zwei Telemetriepunkte.'}
        $lineChart=New-FsMonitorChart 'Selbsttest' 'Dateien/s'
        Set-FsChartPoints $lineChart $sampleRows {param($r)$r.files_per_second}
        if($lineChart.Series[0].Points.Count -lt 1){throw 'Monitor-Zeitreihenpunkt konnte nicht erzeugt werden.'}
        $windowRows=@($sampleRows|Where-Object{$_.sample_type -in @('window','recovery')})
        $scatter=New-FsScatterChart 'Selbsttest' 'Dateien/s'
        Set-FsScatterPoints $scatter $windowRows {param($r)$r.files_per_second} 'Dateien/s'
        if($scatter.Series[0].Points.Count -lt 1){throw 'Monitor-Scatterpunkt konnte nicht erzeugt werden.'}
        if($windowRows.Count -ge 2 -and $scatter.Series.Count -lt 2){throw 'Zeitlich verbundene Scattersegmente wurden nicht erzeugt.'}
        $xyScatter=New-FsScatterChart -Title 'XY-Selbsttest' -YAxisTitle 'MB/s' -XAxisTitle 'Downloads/s' -XAxisFormat '0.00' -YAxisFormat '0.0'
        Set-FsXYScatterPoints $xyScatter $windowRows {param($r)$r.files_per_second} {param($r)if($null -eq $r.bytes_per_second){return $null};([double](Get-FsMonitorScalar $r.bytes_per_second))/1MB} 'Downloads/s' 'MB/s'
        if($windowRows.Count -ge 2 -and $xyScatter.Series.Count -lt 2){throw 'XY-Scatter erzeugt keine zeitlichen Verbindungslinien.'}
        $jitterRows=@(
            [pscustomobject]@{sample_type='window';delay_ms=400;files_per_second=0.5;created_at='2026-08-04T18:00:00Z'},
            [pscustomobject]@{sample_type='live_current';delay_ms=400;files_per_second=0.5;created_at='2026-08-04T18:01:00Z'}
        )
        $jitterChart=New-FsScatterChart 'Jitter-Selbsttest' 'Dateien/s'
        Set-FsScatterPoints $jitterChart $jitterRows {param($r)$r.files_per_second} 'Dateien/s'
        if($jitterChart.Series[0].Points.Count -ne 2 -or [Math]::Abs([double]$jitterChart.Series[0].Points[0].XValue-[double]$jitterChart.Series[0].Points[1].XValue) -lt 0.000001){
            throw 'Überlagerte Scattermarker werden nicht rein visuell getrennt.'
        }
        if($scatter.BackColor -ne [Drawing.Color]::Black){throw 'Monitor-Charts verwenden keinen schwarzen Hintergrund.'}
        Write-Host 'FindSeries Download-Monitor Selbsttest: PASS'
    }elseif($Mode -eq 'Gui'){
        try{Show-FsGuiMonitor}
        catch{
            Write-FsMonitorLog -Message 'Grafischer Monitor konnte nicht gestartet werden.' -ErrorRecord $_
            Show-FsMonitorFatalError -Message ("Der grafische Monitor konnte nicht gestartet werden: {0}" -f $_.Exception.Message)
        }
    }else{
        Show-FsConsoleMonitor
    }
}finally{
    try{$script:MonitorMutex.ReleaseMutex()}catch{}
    try{$script:MonitorMutex.Dispose()}catch{}
}
