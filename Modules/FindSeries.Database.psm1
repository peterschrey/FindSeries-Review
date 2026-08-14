Set-StrictMode -Version 2.0

function Get-FsUtcNowText {
    return [DateTime]::UtcNow.ToString('o')
}

function Get-FsUnixMilliseconds {
    param([DateTime]$Value = [DateTime]::UtcNow)
    $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01T00:00:00', [DateTimeKind]::Utc)
    return [long][Math]::Floor(($Value.ToUniversalTime() - $epoch).TotalMilliseconds)
}


$script:FsDiagnostics = @{
    Enabled = $false
    Console = $false
    SlowSqlMs = 2000
    CsvPath = $null
    ProjectId = $null
    RunId = $null
    Worker = $null
    Stage = $null
}

function Get-FsDiagnosticsConfigValue {
    param([hashtable]$Config,[string]$Name,$Default=$null)
    if($null -eq $Config -or -not $Config.ContainsKey('Diagnostics') -or -not($Config.Diagnostics -is [hashtable])){return $Default}
    if(-not $Config.Diagnostics.ContainsKey($Name)){return $Default}
    return $Config.Diagnostics[$Name]
}

function ConvertTo-FsCsvCell {
    param($Value)
    if($null -eq $Value){return ''}
    if($Value -is [bool]){$text=if($Value){'true'}else{'false'}}
    elseif($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]){$text=[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)}
    else{$text=[string]$Value}
    if($text -match '[,\"\r\n]'){return '"'+$text.Replace('"','""')+'"'}
    return $text
}

function Initialize-FsDiagnostics {
    param(
        [hashtable]$Config,
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Nullable[int]]$ProjectId,
        [Nullable[int]]$RunId,
        [string]$Worker,
        [string]$Stage
    )
    $enabled=[bool](Get-FsDiagnosticsConfigValue -Config $Config -Name 'Profile' -Default $false)
    $script:FsDiagnostics['Enabled']=$enabled
    $script:FsDiagnostics['Console']=[bool](Get-FsDiagnosticsConfigValue -Config $Config -Name 'Console' -Default $true)
    $script:FsDiagnostics['SlowSqlMs']=[int](Get-FsDiagnosticsConfigValue -Config $Config -Name 'SlowSqlMs' -Default 2000)
    $script:FsDiagnostics['ProjectId']=$ProjectId
    $script:FsDiagnostics['RunId']=$RunId
    $script:FsDiagnostics['Worker']=$Worker
    $script:FsDiagnostics['Stage']=$Stage
    if(-not $enabled){return $null}

    $output=[string](Get-FsDiagnosticsConfigValue -Config $Config -Name 'OutputFile' -Default 'Diagnostics\performance.csv')
    $csvPath=if([IO.Path]::IsPathRooted($output)){$output}else{Join-Path $Workspace $output}
    $csvPath=[IO.Path]::GetFullPath($csvPath)
    $directory=Split-Path -Parent $csvPath
    if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    $script:FsDiagnostics['CsvPath']=$csvPath

    $columns=@('timestamp_utc','run_id','project_id','worker','stage','record_type','operation','task_id','query_text','language','attempt','hits','input_count','unique_count','duplicate_count','new_project_media','gate_ms','http_parse_ms','transform_ms','sql_build_ms','bulk_sqlite_ms','lock_wait_ms','sqlite_ms','json_parse_ms','task_complete_ms','total_ms','sql_chars','rows_returned','success','error')
    if(-not(Test-Path -LiteralPath $csvPath -PathType Leaf)){
        $header=($columns -join ',')+[Environment]::NewLine
        [IO.File]::WriteAllText($csvPath,$header,(New-Object Text.UTF8Encoding($false)))
    }
    return $csvPath
}

function Test-FsDiagnosticsEnabled { return [bool]$script:FsDiagnostics['Enabled'] }
function Test-FsDiagnosticsConsoleEnabled { return ([bool]$script:FsDiagnostics['Enabled'] -and [bool]$script:FsDiagnostics['Console']) }
function Get-FsDiagnosticsPath { return $script:FsDiagnostics['CsvPath'] }

function Write-FsPerformanceRecord {
    param([Parameter(Mandatory=$true)][hashtable]$Record)
    if(-not(Test-FsDiagnosticsEnabled)){return}
    $csvPath=[string]$script:FsDiagnostics['CsvPath']
    if([string]::IsNullOrWhiteSpace($csvPath)){return}
    $columns=@('timestamp_utc','run_id','project_id','worker','stage','record_type','operation','task_id','query_text','language','attempt','hits','input_count','unique_count','duplicate_count','new_project_media','gate_ms','http_parse_ms','transform_ms','sql_build_ms','bulk_sqlite_ms','lock_wait_ms','sqlite_ms','json_parse_ms','task_complete_ms','total_ms','sql_chars','rows_returned','success','error')
    $defaults=@{
        timestamp_utc=Get-FsUtcNowText;run_id=$script:FsDiagnostics['RunId'];project_id=$script:FsDiagnostics['ProjectId'];
        worker=$script:FsDiagnostics['Worker'];stage=$script:FsDiagnostics['Stage']
    }
    foreach($key in $Record.Keys){$defaults[[string]$key]=$Record[$key]}
    $line=(($columns|ForEach-Object{ConvertTo-FsCsvCell $defaults[$_]}) -join ',')+[Environment]::NewLine
    $lockPath=$csvPath+'.append.lock';$lock=$null;$deadline=[DateTime]::UtcNow.AddSeconds(10)
    try{
        do{
            try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break}
            catch [IO.IOException]{Start-Sleep -Milliseconds 40}
        }while([DateTime]::UtcNow -lt $deadline)
        if($null -eq $lock){return}
        [IO.File]::AppendAllText($csvPath,$line,(New-Object Text.UTF8Encoding($false)))
    }catch{}
    finally{if($null -ne $lock){try{$lock.Dispose()}catch{}}}
}

function ConvertTo-FsSqlLiteral {
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [bool]) { return $(if ($Value) { '1' } else { '0' }) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [DateTime]) {
        $Value = $Value.ToUniversalTime().ToString('o')
    }

    # ASCII-only UTF-8 hex transport remains safe for apostrophes and arbitrary
    # Unicode. BitConverter performs the expensive conversion in native code;
    # this is substantially faster than appending every byte in PowerShell.
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    if ($bytes.Length -eq 0) { return "CAST(X'' AS TEXT)" }
    $hex = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    return "CAST(X'$hex' AS TEXT)"
}

function Resolve-FsAbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BasePath = (Get-Location).Path
    )
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-FsWorkspacePaths {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $root = Resolve-FsAbsolutePath $Workspace
    return [pscustomobject]@{
        Root       = $root
        Database   = Join-Path $root 'findseries-v5.db'
        Media      = Join-Path $root 'Media'
        Review     = Join-Path $root 'Review'
        Projects   = Join-Path $root 'Projects'
        Logs       = Join-Path $root 'Logs'
        Temp       = Join-Path $root 'Temp'
        Tools      = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools'
    }
}

function Resolve-FsSqlitePath {
    param(
        [string]$SqlitePath,
        [string]$Workspace
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SqlitePath)) { $candidates.Add((Resolve-FsAbsolutePath $SqlitePath)) }
    $moduleParent = Split-Path -Parent $PSScriptRoot
    $candidates.Add((Join-Path $moduleParent 'Tools\sqlite3.exe'))
    $candidates.Add((Join-Path $moduleParent 'Tools/sqlite3'))
    if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
        $paths = Get-FsWorkspacePaths $Workspace
        $candidates.Add((Join-Path $paths.Root 'Tools\sqlite3.exe'))
        $candidates.Add((Join-Path $paths.Root 'Tools/sqlite3'))
    }
    try {
        $cmd = Get-Command sqlite3 -ErrorAction Stop
        if ($cmd.Source) { $candidates.Add([string]$cmd.Source) }
    }
    catch {}

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "sqlite3 wurde nicht gefunden. Führe zuerst .\Install-FindSeriesV5.ps1 aus oder übergib -SqlitePath."
}

function Assert-FsSqliteVersion {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [version]$MinimumVersion = [version]'3.51.3'
    )
    $raw = [string](& $SqlitePath -version)
    $token = ($raw -split '\s+')[0]
    $version = $null
    if (-not [version]::TryParse($token,[ref]$version)) { throw "SQLite-Version konnte nicht ermittelt werden: $raw" }
    if ($version -lt $MinimumVersion) {
        throw "SQLite $version ist zu alt. FindSeries V5 benötigt mindestens $MinimumVersion. Führe .\Install-FindSeriesV5.ps1 -ForceSqliteDownload aus."
    }
    return $version
}

function Test-FsSqlWriteOperation {
    param([string]$Sql)
    if ([string]::IsNullOrWhiteSpace($Sql)) { return $false }
    # Every mutating statement goes through one OS-level file lock. This is
    # independent of SQLite and therefore serializes all FindSeries writers
    # across PowerShell processes before they can compete for SQLite's writer lock.
    return [regex]::IsMatch(
        $Sql,
        '(?im)^\s*(BEGIN\s+IMMEDIATE|INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER|VACUUM|REINDEX|ANALYZE|ATTACH|DETACH)\b'
    )
}

function Get-FsDatabaseWriteLockOwnerText {
    param([Parameter(Mandatory=$true)][string]$LockPath)
    if(-not(Test-Path -LiteralPath $LockPath -PathType Leaf)){return $null}
    $stream=$null
    try {
        $stream=[IO.File]::Open($LockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $length=[Math]::Min(4096,[int]$stream.Length)
        if($length -le 0){return $null}
        $bytes=New-Object byte[] $length
        [void]$stream.Read($bytes,0,$length)
        return [Text.Encoding]::UTF8.GetString($bytes).Trim()
    }
    catch { return $null }
    finally { if($null -ne $stream){try{$stream.Dispose()}catch{}} }
}

function Enter-FsDatabaseWriteLock {
    param(
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [ValidateRange(1000,1800000)][int]$WaitTimeoutMs=300000,
        [string]$ProgressLabel
    )
    $lockPath=$DatabasePath+'.write.lock'
    $directory=Split-Path -Parent $lockPath
    if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $lastNotice=0.0
    while($true){
        try {
            # FileShare.Read keeps the writer exclusive while allowing diagnostics
            # to read the owner payload without disturbing the lock.
            $stream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
            try {
                $processStart=$null
                try{$processStart=(Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')}catch{}
                $payload=[ordered]@{pid=$PID;process_started_at=$processStart;machine=$env:COMPUTERNAME;acquired_at=(Get-FsUtcNowText);label=$ProgressLabel}|ConvertTo-Json -Compress
                $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
                $stream.SetLength(0);$stream.Position=0;$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
            } catch {}
            return $stream
        }
        catch [IO.IOException] {
            if($watch.ElapsedMilliseconds -ge $WaitTimeoutMs){
                $owner=Get-FsDatabaseWriteLockOwnerText -LockPath $lockPath
                $ownerText=if([string]::IsNullOrWhiteSpace($owner)){'Eigentümer nicht lesbar'}else{"Eigentümer: $owner"}
                throw "SQLite-Schreibsperre konnte nach $([Math]::Round($watch.Elapsed.TotalSeconds,1)) s nicht erworben werden: $lockPath. $ownerText"
            }
            if(-not[string]::IsNullOrWhiteSpace($ProgressLabel) -and
               (($watch.Elapsed.TotalSeconds -ge 2 -and $lastNotice -eq 0) -or
                ($watch.Elapsed.TotalSeconds-$lastNotice) -ge 10)){
                $owner=Get-FsDatabaseWriteLockOwnerText -LockPath $lockPath
                $ownerSummary='Eigentümer unbekannt'
                if(-not[string]::IsNullOrWhiteSpace($owner)){
                    try{
                        $ownerObject=$owner|ConvertFrom-Json
                        $ownerSummary=("PID {0}; seit {1}; {2}" -f $ownerObject.pid,$ownerObject.acquired_at,$ownerObject.label)
                    }catch{$ownerSummary=$owner}
                    if($ownerSummary.Length -gt 220){$ownerSummary=$ownerSummary.Substring(0,220)+'...'}
                }
                Write-Host ("        [DB] Warte auf SQLite-Schreibslot: {0} | {1} | belegt durch {2}" -f $ProgressLabel,(Format-FsProgressDuration $watch.Elapsed.TotalSeconds),$ownerSummary) -ForegroundColor DarkYellow
                $lastNotice=$watch.Elapsed.TotalSeconds
            }
            Start-Sleep -Milliseconds (75+(Get-Random -Minimum 0 -Maximum 126))
        }
    }
}

function Exit-FsDatabaseWriteLock {
    param($Lock)
    if($null -ne $Lock){try{$Lock.Dispose()}catch{}}
}

function Invoke-FsSqlite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$Sql,
        [switch]$Query,
        [int]$TimeoutMs = 60000,
        [ValidateRange(0,40)][int]$BusyRetries = 12,
        [ValidateRange(10,10000)][int]$BusyBaseDelayMs = 250,
        [ValidateRange(1000,1800000)][int]$WriteLockTimeoutMs = 300000,
        [ValidateRange(0,3600000)][int]$ExecutionTimeoutMs = 0,
        [string]$ProgressLabel,
        [ValidateRange(1,3600)][int]$ProgressSeconds = 10
    )

    $dbDirectory = Split-Path -Parent $DatabasePath
    if (-not (Test-Path -LiteralPath $dbDirectory)) {
        New-Item -ItemType Directory -Path $dbDirectory -Force | Out-Null
    }

    $profileEnabled=Test-FsDiagnosticsEnabled
    $isWrite=Test-FsSqlWriteOperation -Sql $Sql
    $effectiveExecutionTimeoutMs=if($ExecutionTimeoutMs -gt 0){$ExecutionTimeoutMs}elseif($isWrite){180000}else{900000}
    $lockLabel=$ProgressLabel
    if([string]::IsNullOrWhiteSpace($lockLabel)){
        $oneLine=[regex]::Replace($Sql,'\s+',' ').Trim()
        if($oneLine.Length -gt 140){$oneLine=$oneLine.Substring(0,140)+'...'}
        $lockLabel=$oneLine
    }

    for ($busyAttempt=0; $busyAttempt -le $BusyRetries; $busyAttempt++) {
        $process = $null
        $writeLock=$null
        $retryMessage=$null
        $retryKind=$null
        $profileAttemptWatch=[Diagnostics.Stopwatch]::StartNew()
        $profileLockMs=0.0;$profileSqliteMs=0.0;$profileParseMs=0.0;$profileRows=0;$profileSuccess=$false;$profileError=$null
        try {
            if($isWrite){
                $profileLockWatch=[Diagnostics.Stopwatch]::StartNew()
                $writeLock=Enter-FsDatabaseWriteLock -DatabasePath $DatabasePath -WaitTimeoutMs $WriteLockTimeoutMs -ProgressLabel $lockLabel
                $profileLockMs=$profileLockWatch.Elapsed.TotalMilliseconds
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $SqlitePath
            $psi.Arguments = '"' + $DatabasePath.Replace('"', '""') + '" -batch -bail'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            try {
                $utf8 = New-Object System.Text.UTF8Encoding($false)
                $psi.StandardOutputEncoding = $utf8
                $psi.StandardErrorEncoding = $utf8
            }
            catch {}

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            if (-not $process.Start()) { throw 'sqlite3-Prozess konnte nicht gestartet werden.' }

            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            $prolog = New-Object System.Text.StringBuilder
            [void]$prolog.AppendLine('.timeout ' + [Math]::Max(1000, $TimeoutMs))
            [void]$prolog.AppendLine('.bail on')
            if ($Query) {
                [void]$prolog.AppendLine('.headers on')
                [void]$prolog.AppendLine('.mode json')
            }
            [void]$prolog.AppendLine('PRAGMA foreign_keys=ON;')
            [void]$prolog.AppendLine($Sql)

            $process.StandardInput.Write($prolog.ToString())
            $process.StandardInput.Close()

            $processWatch = [Diagnostics.Stopwatch]::StartNew()
            $lastProgressSeconds = 0.0
            $executionTimedOut=$false
            while (-not $process.WaitForExit(500)) {
                if($processWatch.ElapsedMilliseconds -ge $effectiveExecutionTimeoutMs){
                    $executionTimedOut=$true
                    try{$process.Kill()}catch{}
                    try{[void]$process.WaitForExit(5000)}catch{}
                    break
                }
                if (-not [string]::IsNullOrWhiteSpace($ProgressLabel) -and
                    ($processWatch.Elapsed.TotalSeconds-$lastProgressSeconds) -ge $ProgressSeconds) {
                    Write-Host ("        [DB] {0} | läuft seit {1}" -f $ProgressLabel,(Format-FsProgressDuration $processWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
                    $lastProgressSeconds=$processWatch.Elapsed.TotalSeconds
                }
            }

            $profileSqliteMs=$processWatch.Elapsed.TotalMilliseconds
            if($executionTimedOut){
                $retryMessage="SQLite-Ausführungszeit von $([Math]::Round($effectiveExecutionTimeoutMs/1000.0,1)) s überschritten; sqlite3 wurde beendet. Operation: $lockLabel"
                $retryKind='timeout'
            }
            else {
                $process.WaitForExit()
                $stdout = $stdoutTask.Result
                $stderr = $stderrTask.Result
                $exitCode = $process.ExitCode

                if ($exitCode -ne 0) {
                    $message = if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr.Trim() } else { "sqlite3 ExitCode $exitCode" }
                    $isBusy = $message -match '(?i)(database is locked|database is busy|SQLITE_BUSY|SQLITE_LOCKED)'
                    $isIo = $message -match '(?i)(disk I/O error|SQLITE_IOERR|I/O error \(10\))'
                    if ($isBusy) {
                        $retryMessage=$message
                        $retryKind='busy'
                    }
                    elseif($isIo){
                        # HF57: transient SQLITE_IOERR can occur after a killed or
                        # heavily contended sqlite3 writer. Close this process,
                        # release the external writer lock and retry with backoff.
                        # Persistent storage faults still surface after 3 retries.
                        $retryMessage=$message
                        $retryKind='io'
                    }
                    else { throw "SQLite-Fehler: $message" }
                }
                else {
                    if (-not $Query) {$profileSuccess=$true;return $null}
                    if ([string]::IsNullOrWhiteSpace($stdout)) {$profileSuccess=$true;return @()}
                    try {
                        $profileParseWatch=[Diagnostics.Stopwatch]::StartNew()
                        $parsed = $stdout.Trim() | ConvertFrom-Json
                        $profileParseMs=$profileParseWatch.Elapsed.TotalMilliseconds
                        $profileRows=@($parsed).Count;$profileSuccess=$true
                        return @($parsed)
                    }
                    catch {
                        throw "SQLite-JSON konnte nicht gelesen werden: $($_.Exception.Message)`nAusgabe: $stdout"
                    }
                }
            }
        }
        catch{$profileError=$_.Exception.Message;throw}
        finally {
            if ($null -ne $process) { try{$process.Dispose()}catch{} }
            Exit-FsDatabaseWriteLock -Lock $writeLock
            if($profileEnabled){
                if([string]::IsNullOrWhiteSpace($profileError) -and -not[string]::IsNullOrWhiteSpace($retryMessage)){$profileError=$retryMessage}
                $profileTotalMs=$profileAttemptWatch.Elapsed.TotalMilliseconds
                Write-FsPerformanceRecord -Record @{record_type='sql';operation=$lockLabel;attempt=($busyAttempt+1);lock_wait_ms=[Math]::Round($profileLockMs,3);sqlite_ms=[Math]::Round($profileSqliteMs,3);json_parse_ms=[Math]::Round($profileParseMs,3);total_ms=[Math]::Round($profileTotalMs,3);sql_chars=$Sql.Length;rows_returned=$profileRows;success=$profileSuccess;error=$profileError}
                if((Test-FsDiagnosticsConsoleEnabled) -and $profileTotalMs -ge [int]$script:FsDiagnostics['SlowSqlMs']){
                    Write-Host ("        [PROFILE-SQL] {0} | Lock {1:N0} ms | SQLite {2:N0} ms | Parse {3:N0} ms | Gesamt {4:N0} ms" -f $lockLabel,$profileLockMs,$profileSqliteMs,$profileParseMs,$profileTotalMs) -ForegroundColor DarkMagenta
                }
            }
        }

        if(-not[string]::IsNullOrWhiteSpace($retryMessage)){
            $retryLimit=if($retryKind -eq 'timeout'){
                [Math]::Min(1,$BusyRetries)
            }elseif($retryKind -eq 'io'){
                [Math]::Min(3,$BusyRetries)
            }else{
                $BusyRetries
            }
            if($busyAttempt -ge $retryLimit){
                if($retryKind -eq 'timeout'){throw $retryMessage}
                throw "SQLite-Fehler: $retryMessage"
            }
            $exponent = [Math]::Min(6,$busyAttempt)
            $baseDelay = [Math]::Min(10000,[int]($BusyBaseDelayMs * [Math]::Pow(2,$exponent)))
            if($retryKind -eq 'io'){$baseDelay=[Math]::Max(1000,$baseDelay)}
            $delay = $baseDelay + (Get-Random -Minimum 0 -Maximum 501)
            if (-not [string]::IsNullOrWhiteSpace($ProgressLabel)) {
                $kindText=if($retryKind -eq 'timeout'){'Zeitlimit'}elseif($retryKind -eq 'io'){'I/O-Fehler'}else{'extern belegt'}
                Write-Host ("        [DB] SQLite {0}; Wiederholung {1}/{2} in {3} ms" -f $kindText,($busyAttempt+1),$retryLimit,$delay) -ForegroundColor DarkYellow
            }
            Start-Sleep -Milliseconds $delay
        }
    }
}

function Invoke-FsSqlBatch {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][string[]]$Statements,
        [switch]$Immediate,
        [ValidateRange(1,1000)][int]$BatchSize = 25,
        [scriptblock]$Heartbeat,
        [ValidateRange(1,3600)][int]$HeartbeatSeconds = 60,
        [string]$ProgressLabel,
        [ValidateRange(1,1000)][int]$ProgressEveryChunks = 5
    )
    $all = @($Statements | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($all.Count -eq 0) { return }

    $begin = if ($Immediate) { 'BEGIN IMMEDIATE;' } else { 'BEGIN;' }
    $totalChunks=[int][Math]::Ceiling($all.Count/[double]$BatchSize)
    $heartbeatWatch=[Diagnostics.Stopwatch]::StartNew()

    # Long worker leases are renewed by elapsed time, not before every SQL
    # chunk. The old chunk-wise heartbeat doubled the number of serialized
    # SQLite writes and could turn parallel query workers into a write convoy.
    if ($null -ne $Heartbeat) {
        & $Heartbeat
        $heartbeatWatch.Restart()
    }

    for ($offset=0; $offset -lt $all.Count; $offset += $BatchSize) {
        if ($null -ne $Heartbeat -and $heartbeatWatch.Elapsed.TotalSeconds -ge $HeartbeatSeconds) {
            & $Heartbeat
            $heartbeatWatch.Restart()
        }

        $chunkIndex=[int]($offset/$BatchSize)+1
        $chunk = @($all | Select-Object -Skip $offset -First $BatchSize)
        $sql = $begin + "`n" + ($chunk -join "`n") + "`nCOMMIT;"
        $chunkLabel=$null
        if(-not[string]::IsNullOrWhiteSpace($ProgressLabel)){
            $chunkLabel="$ProgressLabel | SQL-Teil $chunkIndex/$totalChunks"
        }

        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -ProgressLabel $chunkLabel | Out-Null

        if(-not[string]::IsNullOrWhiteSpace($ProgressLabel) -and
           (($chunkIndex % $ProgressEveryChunks) -eq 0 -or $chunkIndex -eq $totalChunks)){
            Write-Host ("        [DB-BATCH] {0}: {1}/{2} SQL-Teile geschrieben" -f $ProgressLabel,$chunkIndex,$totalChunks) -ForegroundColor DarkGray
        }
    }
}

function Normalize-FsDatabaseTitleIdentity {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $value = $Title.Trim().Replace('_',' ')
    $value = $value -replace '^(?i:file:)\s*',''
    $value = [regex]::Replace($value,'\s+',' ').Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Test-FsSqliteTableExists {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$TableName
    )
    $safe = ConvertTo-FsSqlLiteral $TableName
    $rows = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name=$safe LIMIT 1;")
    return ($rows.Count -gt 0)
}

function Get-FsReviewMergeSql {
    <#
      Remaps Review-MVP tables during identity merge when present.
      No-op (empty string) on DBs without review migrations.
      Status conflict priority (safety wins): keep > unsure > reject > unreviewed
      Undo note: later undo must not overwrite a protected current status whose
      batch_id differs from the undone batch (current batch_id is authoritative).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][int]$SurvivorId,
        [Parameter(Mandatory = $true)][int]$DuplicateId,
        [Parameter(Mandatory = $true)][string]$NowSql
    )
    $parts = New-Object Collections.Generic.List[string]

    if (Test-FsSqliteTableExists -SqlitePath $SqlitePath -DatabasePath $DatabasePath -TableName 'media_review_history') {
        [void]$parts.Add(@"
-- Review history must never be silently dropped on media merge.
UPDATE media_review_history SET media_id=$SurvivorId WHERE media_id=$DuplicateId;
"@)
    }

    if (Test-FsSqliteTableExists -SqlitePath $SqlitePath -DatabasePath $DatabasePath -TableName 'media_review_status') {
        [void]$parts.Add(@"
-- Project-scoped current review status: transfer/merge with safety priority.
-- Priority: keep(4) > unsure(3) > reject(2) > unreviewed(1)
INSERT INTO media_review_status(project_id,media_id,status,changed_at,changed_by,source,action,batch_id)
SELECT project_id,$SurvivorId,status,changed_at,changed_by,source,action,batch_id
FROM media_review_status WHERE media_id=$DuplicateId
ON CONFLICT(project_id,media_id) DO UPDATE SET
 status=CASE
   WHEN CASE excluded.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
      > CASE media_review_status.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
   THEN excluded.status ELSE media_review_status.status END,
 changed_at=CASE
   WHEN CASE excluded.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
      > CASE media_review_status.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
   THEN excluded.changed_at
   WHEN CASE excluded.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
      < CASE media_review_status.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
   THEN media_review_status.changed_at
   ELSE MAX(media_review_status.changed_at,excluded.changed_at) END,
 changed_by=CASE
   WHEN CASE excluded.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
      > CASE media_review_status.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
   THEN excluded.changed_by ELSE media_review_status.changed_by END,
 source=CASE
   WHEN CASE excluded.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
      > CASE media_review_status.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
   THEN excluded.source ELSE media_review_status.source END,
 action=CASE
   WHEN CASE excluded.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
      > CASE media_review_status.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
   THEN excluded.action ELSE media_review_status.action END,
 batch_id=CASE
   WHEN CASE excluded.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
      > CASE media_review_status.status WHEN 'keep' THEN 4 WHEN 'unsure' THEN 3 WHEN 'reject' THEN 2 WHEN 'unreviewed' THEN 1 ELSE 0 END
   THEN excluded.batch_id ELSE media_review_status.batch_id END;
DELETE FROM media_review_status WHERE media_id=$DuplicateId;
"@)
    }

    if (Test-FsSqliteTableExists -SqlitePath $SqlitePath -DatabasePath $DatabasePath -TableName 'media_series_keys') {
        [void]$parts.Add(@"
INSERT INTO media_series_keys(project_id,media_id,strategy,series_key,sequence_no,sequence_label,is_primary,built_at)
SELECT project_id,$SurvivorId,strategy,series_key,sequence_no,sequence_label,
 CASE
   WHEN is_primary=1 AND EXISTS(
     SELECT 1 FROM media_series_keys s
     WHERE s.project_id=media_series_keys.project_id AND s.media_id=$SurvivorId AND s.is_primary=1
   ) THEN 0 ELSE is_primary END,
 built_at
FROM media_series_keys WHERE media_id=$DuplicateId
ON CONFLICT(project_id,media_id,strategy,series_key) DO UPDATE SET
 sequence_no=MIN(media_series_keys.sequence_no,excluded.sequence_no);
DELETE FROM media_series_keys WHERE media_id=$DuplicateId;
"@)
    }

    if (Test-FsSqliteTableExists -SqlitePath $SqlitePath -DatabasePath $DatabasePath -TableName 'media_embeddings') {
        [void]$parts.Add(@"
INSERT OR IGNORE INTO media_embeddings(media_id,model_id,status,embedding,embedding_path,error,computed_at,source_sha1)
SELECT $SurvivorId,model_id,status,embedding,embedding_path,error,computed_at,source_sha1
FROM media_embeddings WHERE media_id=$DuplicateId;
DELETE FROM media_embeddings WHERE media_id=$DuplicateId;
"@)
    }

    if (Test-FsSqliteTableExists -SqlitePath $SqlitePath -DatabasePath $DatabasePath -TableName 'media_phash') {
        [void]$parts.Add(@"
INSERT OR IGNORE INTO media_phash(media_id,algorithm,phash,status,computed_at,source_sha1)
SELECT $SurvivorId,algorithm,phash,status,computed_at,source_sha1
FROM media_phash WHERE media_id=$DuplicateId;
DELETE FROM media_phash WHERE media_id=$DuplicateId;
"@)
    }

    if ($parts.Count -eq 0) { return '' }
    return ($parts -join "`n")
}

function Merge-FsMediaRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][int]$SurvivorId,
        [Parameter(Mandatory = $true)][int]$DuplicateId,
        [string]$Reason = 'identity'
    )
    if ($SurvivorId -le 0 -or $DuplicateId -le 0 -or $SurvivorId -eq $DuplicateId) { return $false }
    $now = Get-FsUtcNowText
    $sql = @"
BEGIN IMMEDIATE;
PRAGMA defer_foreign_keys=ON;

-- Preserve all duplicate fields before releasing unique page-id/SHA-1 values.
-- Without this staging row, copying a SHA-1 or page-id to the survivor fails
-- while the duplicate still owns the same value in the unique index.
DROP TABLE IF EXISTS temp.fs_merge_source;
CREATE TEMP TABLE fs_merge_source AS
SELECT * FROM media WHERE id=$DuplicateId;

INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'title',normalized_title,$SurvivorId,'merge-title',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now)
FROM fs_merge_source WHERE normalized_title IS NOT NULL AND length(normalized_title)>0;
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'pageid',cast(page_id AS TEXT),$SurvivorId,'merge-pageid',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now)
FROM fs_merge_source WHERE page_id IS NOT NULL AND page_id>0;
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'sha1',lower(sha1),$SurvivorId,'merge-sha1',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now)
FROM fs_merge_source WHERE sha1 IS NOT NULL AND length(sha1)=40;

-- Release unique identities on the duplicate before assigning them to the survivor.
UPDATE media SET page_id=NULL,sha1=NULL WHERE id=$DuplicateId;

UPDATE media SET
 page_id=COALESCE(NULLIF(page_id,0),(SELECT NULLIF(page_id,0) FROM fs_merge_source LIMIT 1)),
 canonical_title=COALESCE(NULLIF(canonical_title,''),(SELECT NULLIF(canonical_title,'') FROM fs_merge_source LIMIT 1)),
 sha1=COALESCE(NULLIF(sha1,''),(SELECT NULLIF(sha1,'') FROM fs_merge_source LIMIT 1)),
 url=COALESCE(NULLIF(url,''),(SELECT NULLIF(url,'') FROM fs_merge_source LIMIT 1)),
 description_url=COALESCE(NULLIF(description_url,''),(SELECT NULLIF(description_url,'') FROM fs_merge_source LIMIT 1)),
 mime=COALESCE(NULLIF(mime,''),(SELECT NULLIF(mime,'') FROM fs_merge_source LIMIT 1)),
 media_type=COALESCE(NULLIF(media_type,''),(SELECT NULLIF(media_type,'') FROM fs_merge_source LIMIT 1)),
 size=COALESCE(size,(SELECT size FROM fs_merge_source LIMIT 1)),
 width=COALESCE(width,(SELECT width FROM fs_merge_source LIMIT 1)),
 height=COALESCE(height,(SELECT height FROM fs_merge_source LIMIT 1)),
 current_uploader=COALESCE(NULLIF(current_uploader,''),(SELECT NULLIF(current_uploader,'') FROM fs_merge_source LIMIT 1)),
 current_timestamp=COALESCE(NULLIF(current_timestamp,''),(SELECT NULLIF(current_timestamp,'') FROM fs_merge_source LIMIT 1)),
 original_uploader=COALESCE(NULLIF(original_uploader,''),(SELECT NULLIF(original_uploader,'') FROM fs_merge_source LIMIT 1)),
 original_timestamp=COALESCE(NULLIF(original_timestamp,''),(SELECT NULLIF(original_timestamp,'') FROM fs_merge_source LIMIT 1)),
 description=COALESCE(NULLIF(description,''),(SELECT NULLIF(description,'') FROM fs_merge_source LIMIT 1)),
 creator=COALESCE(NULLIF(creator,''),(SELECT NULLIF(creator,'') FROM fs_merge_source LIMIT 1)),
 license=COALESCE(NULLIF(license,''),(SELECT NULLIF(license,'') FROM fs_merge_source LIMIT 1)),
 license_url=COALESCE(NULLIF(license_url,''),(SELECT NULLIF(license_url,'') FROM fs_merge_source LIMIT 1)),
 attribution=COALESCE(NULLIF(attribution,''),(SELECT NULLIF(attribution,'') FROM fs_merge_source LIMIT 1)),
 latitude=COALESCE(latitude,(SELECT latitude FROM fs_merge_source LIMIT 1)),
 longitude=COALESCE(longitude,(SELECT longitude FROM fs_merge_source LIMIT 1)),
 metadata_json=CASE WHEN metadata_level >= COALESCE((SELECT metadata_level FROM fs_merge_source LIMIT 1),0) THEN metadata_json ELSE (SELECT metadata_json FROM fs_merge_source LIMIT 1) END,
 metadata_level=MAX(metadata_level,COALESCE((SELECT metadata_level FROM fs_merge_source LIMIT 1),0)),
 metadata_checked_level=MAX(metadata_checked_level,COALESCE((SELECT metadata_checked_level FROM fs_merge_source LIMIT 1),0)),
 updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE id=$SurvivorId;

INSERT INTO project_media(project_id,media_id,score,best_source,selected,download_requested,first_seen_at,updated_at)
SELECT project_id,$SurvivorId,score,best_source,selected,download_requested,first_seen_at,updated_at FROM project_media WHERE media_id=$DuplicateId
ON CONFLICT(project_id,media_id) DO UPDATE SET
 score=MAX(project_media.score,excluded.score),
 best_source=CASE WHEN excluded.score>=project_media.score THEN excluded.best_source ELSE project_media.best_source END,
 selected=MAX(project_media.selected,excluded.selected),
 download_requested=MAX(project_media.download_requested,excluded.download_requested),
 first_seen_at=MIN(project_media.first_seen_at,excluded.first_seen_at),
 updated_at=MAX(project_media.updated_at,excluded.updated_at);
DELETE FROM project_media WHERE media_id=$DuplicateId;

INSERT OR IGNORE INTO discoveries(project_id,media_id,source_type,source_value,score,language,query_text,origin_category_id,parent_media_id,details_json,created_at)
SELECT project_id,
       CASE WHEN media_id=$DuplicateId THEN $SurvivorId ELSE media_id END,
       source_type,source_value,score,language,query_text,origin_category_id,
       CASE WHEN parent_media_id=$DuplicateId THEN $SurvivorId ELSE parent_media_id END,
       details_json,created_at
FROM discoveries WHERE media_id=$DuplicateId OR parent_media_id=$DuplicateId;
DELETE FROM discoveries WHERE media_id=$DuplicateId OR parent_media_id=$DuplicateId;

INSERT INTO metadata_tasks(project_id,media_id,required_level,status,lease_owner,lease_until,attempts,last_error,updated_at)
SELECT project_id,$SurvivorId,required_level,status,lease_owner,lease_until,attempts,last_error,updated_at FROM metadata_tasks WHERE media_id=$DuplicateId
ON CONFLICT(project_id,media_id) DO UPDATE SET
 required_level=MAX(metadata_tasks.required_level,excluded.required_level),
 status=CASE
   WHEN metadata_tasks.status='done' OR excluded.status='done' THEN 'done'
   WHEN metadata_tasks.status='running' OR excluded.status='running' THEN 'running'
   WHEN metadata_tasks.status='pending' OR excluded.status='pending' THEN 'pending'
   ELSE excluded.status END,
 attempts=MAX(metadata_tasks.attempts,excluded.attempts),
 last_error=COALESCE(metadata_tasks.last_error,excluded.last_error),
 updated_at=MAX(metadata_tasks.updated_at,excluded.updated_at);
DELETE FROM metadata_tasks WHERE media_id=$DuplicateId;

INSERT INTO neighbor_tasks(project_id,media_id,status,continuation_json,lease_owner,lease_until,attempts,api_pages,results_count,last_error,updated_at)
SELECT project_id,$SurvivorId,status,continuation_json,lease_owner,lease_until,attempts,api_pages,results_count,last_error,updated_at FROM neighbor_tasks WHERE media_id=$DuplicateId
ON CONFLICT(project_id,media_id) DO UPDATE SET
 status=CASE
   WHEN neighbor_tasks.status='done' OR excluded.status='done' THEN 'done'
   WHEN neighbor_tasks.status='running' OR excluded.status='running' THEN 'running'
   WHEN neighbor_tasks.status='pending' OR excluded.status='pending' THEN 'pending'
   ELSE excluded.status END,
 attempts=MAX(neighbor_tasks.attempts,excluded.attempts),
 api_pages=MAX(neighbor_tasks.api_pages,excluded.api_pages),
 results_count=MAX(neighbor_tasks.results_count,excluded.results_count),
 last_error=COALESCE(neighbor_tasks.last_error,excluded.last_error),
 updated_at=MAX(neighbor_tasks.updated_at,excluded.updated_at);
DELETE FROM neighbor_tasks WHERE media_id=$DuplicateId;

INSERT INTO downloads(media_id,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,lease_owner,lease_until,attempts,last_error,created_at,updated_at)
SELECT $SurvivorId,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,lease_owner,lease_until,attempts,last_error,created_at,updated_at FROM downloads WHERE media_id=$DuplicateId
ON CONFLICT(media_id) DO UPDATE SET
 status=CASE
   WHEN downloads.status='done' OR excluded.status='done' THEN 'done'
   WHEN downloads.status='historical' OR excluded.status='historical' THEN 'historical'
   WHEN downloads.status='running' OR excluded.status='running' THEN 'running'
   WHEN downloads.status='pending' OR excluded.status='pending' THEN 'pending'
   ELSE excluded.status END,
 local_path=COALESCE(downloads.local_path,excluded.local_path),
 bytes=MAX(COALESCE(downloads.bytes,0),COALESCE(excluded.bytes,0)),
 verified_sha1=COALESCE(downloads.verified_sha1,excluded.verified_sha1),
 historical_complete=MAX(downloads.historical_complete,excluded.historical_complete),
 owner_project_id=COALESCE(downloads.owner_project_id,excluded.owner_project_id),
 attempts=MAX(downloads.attempts,excluded.attempts),
 last_error=COALESCE(downloads.last_error,excluded.last_error),
 created_at=MIN(downloads.created_at,excluded.created_at),
 updated_at=MAX(downloads.updated_at,excluded.updated_at);
DELETE FROM downloads WHERE media_id=$DuplicateId;

INSERT OR IGNORE INTO download_history(media_id,project_id,source_kind,source_path,status,local_path,local_filename,registered_at,imported_at,details_json)
SELECT $SurvivorId,project_id,source_kind,source_path,status,local_path,local_filename,registered_at,imported_at,details_json
FROM download_history WHERE media_id=$DuplicateId;
DELETE FROM download_history WHERE media_id=$DuplicateId;

INSERT INTO project_downloads(project_id,media_id,status,lease_owner,lease_until,attempts,last_error,updated_at)
SELECT project_id,$SurvivorId,status,lease_owner,lease_until,attempts,last_error,updated_at FROM project_downloads WHERE media_id=$DuplicateId
ON CONFLICT(project_id,media_id) DO UPDATE SET
 status=CASE
   WHEN project_downloads.status IN ('done','reused') THEN project_downloads.status
   WHEN excluded.status IN ('done','reused') THEN excluded.status
   WHEN project_downloads.status='running' OR excluded.status='running' THEN 'running'
   WHEN project_downloads.status='pending' OR excluded.status='pending' THEN 'pending'
   ELSE excluded.status END,
 attempts=MAX(project_downloads.attempts,excluded.attempts),
 last_error=COALESCE(project_downloads.last_error,excluded.last_error),
 updated_at=MAX(project_downloads.updated_at,excluded.updated_at);
DELETE FROM project_downloads WHERE media_id=$DuplicateId;

-- Preserve review/rejection state when identity repair merges two media rows.
UPDATE OR IGNORE media_rejections SET media_id=$SurvivorId,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id=$DuplicateId;
UPDATE media_rejections SET media_id=NULL,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id=$DuplicateId;
UPDATE review_exports
SET status='superseded',rejected_at=COALESCE(rejected_at,$(ConvertTo-FsSqlLiteral $now))
WHERE media_id=$DuplicateId
  AND EXISTS(SELECT 1 FROM review_exports x WHERE x.project_id=review_exports.project_id AND x.media_id=$SurvivorId);
UPDATE review_exports SET media_id=$SurvivorId WHERE media_id=$DuplicateId AND status<>'superseded';

$(Get-FsReviewMergeSql -SurvivorId $SurvivorId -DuplicateId $DuplicateId -NowSql (ConvertTo-FsSqlLiteral $now) -SqlitePath $SqlitePath -DatabasePath $DatabasePath)

-- A rejection may only become provable after metadata reveals a shared SHA-1.
-- Re-apply the global exclusion after the merge so an alias discovered through
-- another title/page cannot remain selected or downloadable.
UPDATE project_media
SET selected=0,download_requested=0,updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE media_id=$SurvivorId AND (
 EXISTS(SELECT 1 FROM media_rejections r WHERE r.media_id=$SurvivorId)
 OR EXISTS(SELECT 1 FROM media m JOIN media_rejections r ON r.page_id=m.page_id WHERE m.id=$SurvivorId AND m.page_id IS NOT NULL)
 OR EXISTS(SELECT 1 FROM media m JOIN media_rejections r ON r.sha1=m.sha1 COLLATE NOCASE WHERE m.id=$SurvivorId AND m.sha1 IS NOT NULL AND m.sha1<>'')
 OR EXISTS(SELECT 1 FROM media m JOIN media_rejections r ON r.normalized_title=m.normalized_title COLLATE NOCASE WHERE m.id=$SurvivorId AND m.normalized_title IS NOT NULL AND m.normalized_title<>'')
);
UPDATE metadata_tasks SET status='skipped',lease_owner=NULL,lease_until=NULL,last_error='Global verworfen',updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE media_id=$SurvivorId AND EXISTS(SELECT 1 FROM project_media pm WHERE pm.media_id=$SurvivorId AND pm.selected=0);
UPDATE neighbor_tasks SET status='skipped',lease_owner=NULL,lease_until=NULL,last_error='Global verworfen',updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE media_id=$SurvivorId AND EXISTS(SELECT 1 FROM project_media pm WHERE pm.media_id=$SurvivorId AND pm.selected=0);
UPDATE project_downloads SET status='skipped',lease_owner=NULL,lease_until=NULL,last_error='Global verworfen',updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE media_id=$SurvivorId AND EXISTS(SELECT 1 FROM project_media pm WHERE pm.media_id=$SurvivorId AND pm.selected=0);
UPDATE downloads SET status='rejected',historical_complete=1,lease_owner=NULL,lease_until=NULL,last_error='Global verworfen',updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE media_id=$SurvivorId AND EXISTS(SELECT 1 FROM project_media pm WHERE pm.media_id=$SurvivorId AND pm.selected=0);
UPDATE review_exports SET status='rejected',rejected_at=COALESCE(rejected_at,$(ConvertTo-FsSqlLiteral $now))
WHERE media_id=$SurvivorId AND EXISTS(SELECT 1 FROM project_media pm WHERE pm.media_id=$SurvivorId AND pm.selected=0);

UPDATE media_identities SET media_id=$SurvivorId,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id=$DuplicateId;
DELETE FROM media_identity_conflicts WHERE media_id_a IN ($SurvivorId,$DuplicateId) OR media_id_b IN ($SurvivorId,$DuplicateId);
INSERT INTO media_merge_log(survivor_media_id,duplicate_media_id,reason,merged_at)
VALUES($SurvivorId,$DuplicateId,$(ConvertTo-FsSqlLiteral $Reason),$(ConvertTo-FsSqlLiteral $now));
DELETE FROM media WHERE id=$DuplicateId;
DROP TABLE IF EXISTS temp.fs_merge_source;
COMMIT;
"@
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql | Out-Null
    return $true
}

function Get-FsPreferredMediaId {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][int[]]$MediaIds
    )
    $ids = @($MediaIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return 0 }
    if ($ids.Count -eq 1) { return [int]$ids[0] }
    $idList = $ids -join ','
    $rows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT m.id
FROM media m
LEFT JOIN downloads d ON d.media_id=m.id
WHERE m.id IN ($idList)
ORDER BY CASE WHEN d.historical_complete=1 AND d.status IN ('done','historical') THEN 0 ELSE 1 END,
         m.metadata_level DESC,
         CASE WHEN m.page_id IS NOT NULL AND m.page_id>0 THEN 0 ELSE 1 END,
         m.id ASC
LIMIT 1;
"@
    if (@($rows).Count -eq 0) { return [int]$ids[0] }
    return [int]$rows[0].id
}

function Sync-FsMediaIdentities {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [switch]$ShowProgress,
        [ValidateRange(100,100000)][int]$BatchSize = 5000
    )

    $bounds=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql 'SELECT COALESCE(MIN(id),0) min_id,COALESCE(MAX(id),0) max_id,COUNT(*) count FROM media;')
    if($bounds.Count -eq 0 -or [long]$bounds[0].count -eq 0){return}

    $minId=[long]$bounds[0].min_id
    $maxId=[long]$bounds[0].max_id
    $totalRows=[long]$bounds[0].count
    $range=[long](($maxId-$minId)+1)
    if($range -lt 1){$range=1}
    $totalBatches=[int][Math]::Ceiling($range/[double]$BatchSize)
    $now = Get-FsUtcNowText
    $watch=[Diagnostics.Stopwatch]::StartNew()

    for($batchIndex=0;$batchIndex -lt $totalBatches;$batchIndex++){
        $lowerExclusive=($minId-1)+([long]$batchIndex*$BatchSize)
        $upperInclusive=[long]($lowerExclusive+$BatchSize)
        if($upperInclusive -gt $maxId){$upperInclusive=$maxId}
        $label=$null
        if($ShowProgress){
            $label=("Identitätstabellen mit Medienbestand abgleichen | Teil {0}/{1}" -f ($batchIndex+1),$totalBatches)
        }

        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'title',normalized_title,id,'schema-sync',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now)
FROM media
WHERE id>$lowerExclusive AND id<=$upperInclusive
  AND normalized_title IS NOT NULL AND length(normalized_title)>0;
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'pageid',cast(page_id AS TEXT),id,'schema-sync',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now)
FROM media
WHERE id>$lowerExclusive AND id<=$upperInclusive
  AND page_id IS NOT NULL AND page_id>0;
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'sha1',lower(sha1),id,'schema-sync',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now)
FROM media
WHERE id>$lowerExclusive AND id<=$upperInclusive
  AND sha1 IS NOT NULL AND length(sha1)=40;
"@ -ProgressLabel $label | Out-Null

        if($ShowProgress){
            $completed=$batchIndex+1
            $percent=[Math]::Min(100,[Math]::Round(($completed*100.0)/$totalBatches,1))
            $elapsed=[Math]::Max(0.001,$watch.Elapsed.TotalSeconds)
            $rate=$completed/$elapsed
            $remaining=$totalBatches-$completed
            $etaSeconds=if($rate -gt 0){$remaining/$rate}else{-1}
            $status=("{0}/{1} Teile | ungefähr {2:N0} Medien | Restdauer {3}" -f $completed,$totalBatches,$totalRows,(Format-FsProgressDuration $etaSeconds))
            Write-Progress -Activity 'Identitätstabellen synchronisieren' -Status $status -PercentComplete $percent
            if($completed -eq 1 -or ($completed % 5) -eq 0 -or $completed -eq $totalBatches){
                Write-Host ("        [DB] Identitätsabgleich: {0}" -f $status) -ForegroundColor DarkGray
            }
        }
    }

    if($ShowProgress){Write-Progress -Activity 'Identitätstabellen synchronisieren' -Completed}
}


function Format-FsProgressDuration {
    param([double]$Seconds)
    if($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)){return '--:--'}
    $span=[TimeSpan]::FromSeconds($Seconds)
    if($span.TotalDays -ge 1){return $span.ToString('d\.hh\:mm\:ss')}
    if($span.TotalHours -ge 1){return $span.ToString('hh\:mm\:ss')}
    return $span.ToString('mm\:ss')
}

function Get-FsMediaIdentityConflictEstimate {
    param([string]$SqlitePath,[string]$DatabasePath,[switch]$ShowProgress)
    try {
        $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM media_identity_conflicts) explicit_conflicts,
 (SELECT COALESCE(SUM(cnt-1),0) FROM (SELECT COUNT(*) cnt FROM media WHERE page_id IS NOT NULL AND page_id>0 GROUP BY page_id HAVING COUNT(*)>1)) pageid_duplicates,
 (SELECT COALESCE(SUM(cnt-1),0) FROM (SELECT COUNT(*) cnt FROM media WHERE sha1 IS NOT NULL AND length(sha1)=40 GROUP BY lower(sha1) HAVING COUNT(*)>1)) sha1_duplicates,
 (SELECT COUNT(*) FROM media m JOIN media_identities mi ON mi.identity_type='title' AND mi.identity_value=m.normalized_title WHERE m.id<>mi.media_id) title_conflicts;
"@ -ProgressLabel $(if($ShowProgress){'Medienkonflikte zählen'}else{$null}))
        if($rows.Count -eq 0){return 0}
        return [int]$rows[0].explicit_conflicts+[int]$rows[0].pageid_duplicates+[int]$rows[0].sha1_duplicates+[int]$rows[0].title_conflicts
    }
    catch { return 0 }
}

function Get-FsPendingMediaIdentityConflictCount {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath
    )
    $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql 'SELECT COUNT(*) count FROM media_identity_conflicts;')
    if($rows.Count -eq 0){return 0}
    return [int]$rows[0].count
}

function Repair-FsMediaIdentityConflicts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [int]$MaxPairs = 1000,
        [switch]$SkipLock,
        [switch]$QueueOnly,
        [switch]$ShowProgress,
        [string]$ProgressActivity = 'Medienidentitäten prüfen',
        [ValidateRange(1,10000)][int]$ProgressEvery = 25
    )
    $owner = 'media-repair-' + $PID + '-' + [Guid]::NewGuid().ToString('N')
    $watch=[Diagnostics.Stopwatch]::StartNew()
    if($ShowProgress -and -not $SkipLock){Write-Host '        [DB] Identitäts-Lock anfordern; maximale Wartezeit 2 Minuten ...' -ForegroundColor DarkGray}
    $locked = $SkipLock -or (Acquire-FsNamedLock -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Name 'media-identity-repair' -Owner $owner -LeaseSeconds 1800 -WaitSeconds 120)
    if (-not $locked) {
        if($ShowProgress){Write-Warning 'Medienidentitäten konnten nicht geprüft werden: Lock nicht erhalten.'}
        return 0
    }
    $merged = 0
    $estimate=0
    $lastHostStatus=[DateTime]::UtcNow.AddYears(-1)
    try {
        if($QueueOnly){
            # Seit Schema-Migration V2 werden Medien und Identitäten gemeinsam
            # geschrieben. Beim normalen Resume ist deshalb ausschließlich die
            # persistente Konfliktqueue maßgeblich; ein Vollscan über sämtliche
            # Medien wäre redundant und kann bei großen Workspaces minutenlang
            # laufen beziehungsweise das SQLite-Zeitlimit überschreiten.
            $estimate=Get-FsPendingMediaIdentityConflictCount -SqlitePath $SqlitePath -DatabasePath $DatabasePath
            if($ShowProgress){Write-Host ("        [DB] Konfliktqueue direkt verarbeiten; kein vollständiger Identitätsabgleich ({0:N0} Eintrag/Einträge)." -f $estimate) -ForegroundColor DarkGray}
        }
        else{
            if($ShowProgress){Write-Host '        [DB] Identitätstabellen synchronisieren ...' -ForegroundColor DarkGray}
            $syncWatch=[Diagnostics.Stopwatch]::StartNew()
            Sync-FsMediaIdentities -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ShowProgress:$ShowProgress
            if($ShowProgress){Write-Host ("        [DB] Identitätstabellen synchronisiert in {0}." -f (Format-FsProgressDuration $syncWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray}
            $estimateWatch=[Diagnostics.Stopwatch]::StartNew()
            $estimate=Get-FsMediaIdentityConflictEstimate -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ShowProgress:$ShowProgress
            if($ShowProgress){Write-Host ("        [DB] Konfliktzählung abgeschlossen in {0}." -f (Format-FsProgressDuration $estimateWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray}
        }
        if($ShowProgress){
            if($estimate -gt 0){Write-Host ("        [DB] ungefähr {0:N0} Konflikt(e) erkannt; Restdauer und Abschlusszeit folgen nach den ersten Zusammenführungen." -f $estimate) -ForegroundColor DarkGray}
            else{Write-Host '        [DB] keine vorab zählbaren Konflikte; Restprüfung läuft.' -ForegroundColor DarkGray}
        }
        while ($merged -lt $MaxPairs) {
            $pair = @()
            $conflict = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql 'SELECT media_id_a,media_id_b,reason FROM media_identity_conflicts ORDER BY created_at,media_id_a,media_id_b LIMIT 1;')
            if ($conflict.Count -gt 0) {
                $ids = @([int]$conflict[0].media_id_a,[int]$conflict[0].media_id_b)
                $existing = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql ("SELECT id FROM media WHERE id IN ("+($ids -join ',')+");"))
                if ($existing.Count -lt 2) {
                    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "DELETE FROM media_identity_conflicts WHERE media_id_a=$($ids[0]) AND media_id_b=$($ids[1]);" | Out-Null
                    continue
                }
                $survivor = Get-FsPreferredMediaId -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MediaIds $ids
                $duplicate = [int](@($ids | Where-Object { $_ -ne $survivor })[0])
                $pair = @([pscustomobject]@{survivor_id=$survivor;duplicate_id=$duplicate;reason=[string]$conflict[0].reason})
            }
            if($QueueOnly -and $pair.Count -eq 0){break}
            if ($pair.Count -eq 0) { $pair = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT mi.media_id AS survivor_id,m.id AS duplicate_id,'title-identity' AS reason
FROM media m
JOIN media_identities mi ON mi.identity_type='title' AND mi.identity_value=m.normalized_title
WHERE m.id<>mi.media_id
LIMIT 1;
"@) }
            if ($pair.Count -eq 0) {
                $group = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT group_concat(id) ids,'pageid' reason FROM media WHERE page_id IS NOT NULL AND page_id>0 GROUP BY page_id HAVING COUNT(*)>1 LIMIT 1;")
                if ($group.Count -gt 0) {
                    $ids = @(([string]$group[0].ids -split ',') | ForEach-Object { [int]$_ })
                    $survivor = Get-FsPreferredMediaId -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MediaIds $ids
                    $duplicate = @($ids | Where-Object { $_ -ne $survivor } | Select-Object -First 1)
                    if ($duplicate.Count -gt 0) { $pair = @([pscustomobject]@{survivor_id=$survivor;duplicate_id=[int]$duplicate[0];reason='pageid'}) }
                }
            }
            if ($pair.Count -eq 0) {
                $group = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT group_concat(id) ids,'sha1' reason FROM media WHERE sha1 IS NOT NULL AND length(sha1)=40 GROUP BY lower(sha1) HAVING COUNT(*)>1 LIMIT 1;")
                if ($group.Count -gt 0) {
                    $ids = @(([string]$group[0].ids -split ',') | ForEach-Object { [int]$_ })
                    $survivor = Get-FsPreferredMediaId -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MediaIds $ids
                    $duplicate = @($ids | Where-Object { $_ -ne $survivor } | Select-Object -First 1)
                    if ($duplicate.Count -gt 0) { $pair = @([pscustomobject]@{survivor_id=$survivor;duplicate_id=[int]$duplicate[0];reason='sha1'}) }
                }
            }
            if ($pair.Count -eq 0) { break }
            [void](Merge-FsMediaRows -SqlitePath $SqlitePath -DatabasePath $DatabasePath -SurvivorId ([int]$pair[0].survivor_id) -DuplicateId ([int]$pair[0].duplicate_id) -Reason ([string]$pair[0].reason))
            $merged++

            # Merge-FsMediaRows übernimmt sämtliche Identitäten des Duplikats
            # atomar auf den Survivor. Ein erneuter Vollabgleich nach jedem Paar
            # ist daher weder erforderlich noch zulässig für große Bestände.
            if($ShowProgress){
                $elapsed=[Math]::Max(0.001,$watch.Elapsed.TotalSeconds)
                $rate=$merged/$elapsed
                $remaining=if($estimate -gt $merged){$estimate-$merged}else{0}
                $etaSeconds=if($estimate -gt 0 -and $rate -gt 0){$remaining/$rate}else{-1}
                $etaText=Format-FsProgressDuration $etaSeconds
                $finishText=if($etaSeconds -ge 0){[DateTime]::Now.AddSeconds($etaSeconds).ToString('dd.MM.yyyy HH:mm:ss')}else{'--'}
                $percent=if($estimate -gt 0){[Math]::Min(99,[Math]::Round(($merged*100.0)/$estimate,1))}else{0}
                $status=("{0:N0} zusammengeführt | {1:N2}/s | Restdauer {2} | Ende ca. {3}" -f $merged,$rate,$etaText,$finishText)
                Write-Progress -Activity $ProgressActivity -Status $status -PercentComplete $percent
                $now=[DateTime]::UtcNow
                if($merged -eq 1 -or ($merged % $ProgressEvery) -eq 0 -or ($now-$lastHostStatus).TotalSeconds -ge 20){
                    Write-Host ("        [DB] {0}" -f $status) -ForegroundColor DarkGray
                    $lastHostStatus=$now
                }
            }
        }
        if($ShowProgress){
            Write-Progress -Activity $ProgressActivity -Completed
            Write-Host ("        [DB] Identitätsprüfung abgeschlossen: {0:N0} zusammengeführt in {1}." -f $merged,(Format-FsProgressDuration $watch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
        }
        return $merged
    }
    finally {
        if($ShowProgress){Write-Progress -Activity $ProgressActivity -Completed}
        if (-not $SkipLock) {
            $releaseWatch=[Diagnostics.Stopwatch]::StartNew()
            if($ShowProgress){Write-Host '        [DB] Identitäts-Lock freigeben ...' -ForegroundColor DarkGray}
            Release-FsNamedLock -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Name 'media-identity-repair' -Owner $owner
            if($ShowProgress){Write-Host ("        [DB] Identitäts-Lock freigegeben in {0}." -f (Format-FsProgressDuration $releaseWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray}
        }
    }
}

function Invoke-FsMediaIdentityMigration {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [switch]$ShowProgress
    )
    $row = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql 'SELECT version FROM schema_migrations WHERE version=2;')
    if ($row.Count -gt 0) {
        # Datensätze werden seit Migration V2 transaktional zusammen mit ihren
        # Identitäten geschrieben. Deshalb ist beim normalen Start nur die
        # persistente Konfliktqueue zu prüfen; der bisherige Vollabgleich aller
        # Medien kostete bei großen Beständen unnötig Zeit.
        $pendingConflicts=Get-FsPendingMediaIdentityConflictCount -SqlitePath $SqlitePath -DatabasePath $DatabasePath
        if($pendingConflicts -gt 0){
            if($ShowProgress){Write-Host ("        [DB] {0:N0} offene Identitätskonflikt(e); Reparatur wird fortgesetzt." -f $pendingConflicts) -ForegroundColor DarkGray}
            [void](Repair-FsMediaIdentityConflicts -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MaxPairs 10000 -QueueOnly -ShowProgress:$ShowProgress -ProgressActivity 'Medienidentitäten beim Start prüfen')
        }
        elseif($ShowProgress){
            Write-Host '        [DB] keine offenen Identitätskonflikte; vollständiger Bestandsabgleich nicht erforderlich.' -ForegroundColor DarkGray
        }
        return
    }
    $owner = 'schema-v2-' + $PID
    if (-not (Acquire-FsNamedLock -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Name 'schema-v2-media-identities' -Owner $owner -LeaseSeconds 3600 -WaitSeconds 300)) {
        throw 'Schema-Migration V2 konnte den Datenbank-Lock nicht erwerben.'
    }
    try {
        $again = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql 'SELECT version FROM schema_migrations WHERE version=2;')
        if ($again.Count -gt 0) { return }
        $columns = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql 'PRAGMA table_info(media);')
        if (-not (@($columns.name) -contains 'normalized_title')) {
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql 'ALTER TABLE media ADD COLUMN normalized_title TEXT COLLATE NOCASE;' | Out-Null
        }
        $titleRows = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT id,title FROM media WHERE normalized_title IS NULL OR normalized_title='';")
        $titleStatements = New-Object System.Collections.Generic.List[string]
        $titleIndex=0
        $titleWatch=[Diagnostics.Stopwatch]::StartNew()
        foreach ($titleRow in $titleRows) {
            $titleIndex++
            $titleKey = Normalize-FsDatabaseTitleIdentity ([string]$titleRow.title)
            if ($titleKey) { $titleStatements.Add("UPDATE media SET normalized_title=$(ConvertTo-FsSqlLiteral $titleKey) WHERE id=$([int]$titleRow.id);") }
            if ($titleStatements.Count -ge 500) { Invoke-FsSqlBatch -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Statements $titleStatements.ToArray() -Immediate; $titleStatements.Clear() }
            if($ShowProgress -and ($titleIndex -eq 1 -or ($titleIndex % 500) -eq 0)){
                $rate=$titleIndex/[Math]::Max(0.001,$titleWatch.Elapsed.TotalSeconds)
                $remaining=@($titleRows).Count-$titleIndex
                $etaSeconds=if($rate -gt 0){$remaining/$rate}else{-1}
                $eta=Format-FsProgressDuration $etaSeconds
                $finish=if($etaSeconds -ge 0){[DateTime]::Now.AddSeconds($etaSeconds).ToString('dd.MM.yyyy HH:mm:ss')}else{'--'}
                Write-Progress -Activity 'Schema-Migration: Titel normalisieren' -Status ("$titleIndex/$(@($titleRows).Count) | Restdauer $eta | Ende ca. $finish") -PercentComplete (($titleIndex*100.0)/[Math]::Max(1,@($titleRows).Count))
            }
        }
        if($ShowProgress){Write-Progress -Activity 'Schema-Migration: Titel normalisieren' -Completed}
        if ($titleStatements.Count -gt 0) { Invoke-FsSqlBatch -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Statements $titleStatements.ToArray() -Immediate }
        $merged = Repair-FsMediaIdentityConflicts -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MaxPairs 100000 -SkipLock -ShowProgress:$ShowProgress -ProgressActivity 'Schema-Migration: Medienidentitäten'
        $now = Get-FsUtcNowText
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
CREATE INDEX IF NOT EXISTS ix_media_normalized_title ON media(normalized_title);
CREATE UNIQUE INDEX IF NOT EXISTS ux_media_page_id_identity ON media(page_id) WHERE page_id IS NOT NULL AND page_id>0;
CREATE UNIQUE INDEX IF NOT EXISTS ux_media_sha1_identity ON media(sha1 COLLATE NOCASE) WHERE sha1 IS NOT NULL AND length(sha1)=40;
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(2,$(ConvertTo-FsSqlLiteral $now));
INSERT INTO settings(key,value,updated_at) VALUES('media_identity_merge_count',$(ConvertTo-FsSqlLiteral ([string]$merged)),$(ConvertTo-FsSqlLiteral $now))
ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at;
"@ | Out-Null
    }
    finally {
        Release-FsNamedLock -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Name 'schema-v2-media-identities' -Owner $owner
    }
}


function Ensure-FsDownloadTuningSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$SqlitePath,
        [Parameter(Mandatory=$true)][string]$DatabasePath
    )

    # HF31 keeps the autotune schema as a small explicit migration. This is
    # deliberately separate from the large base schema so existing workspaces,
    # status queries and the detached monitor can initialize it reliably.
    $schema=@'
CREATE TABLE IF NOT EXISTS download_tuning (
    project_id INTEGER PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    run_id INTEGER REFERENCES runs(id) ON DELETE SET NULL,
    enabled INTEGER NOT NULL DEFAULT 0,
    current_delay_ms INTEGER NOT NULL DEFAULT 0,
    direction INTEGER NOT NULL DEFAULT -1,
    step_ms INTEGER NOT NULL DEFAULT 20,
    window_target INTEGER NOT NULL DEFAULT 100,
    window_successes INTEGER NOT NULL DEFAULT 0,
    window_bytes INTEGER NOT NULL DEFAULT 0,
    window_started_at_ms INTEGER NOT NULL DEFAULT 0,
    previous_files_per_second REAL,
    previous_bytes_per_second REAL,
    last_window_delay_ms INTEGER,
    last_window_successes INTEGER NOT NULL DEFAULT 0,
    last_window_elapsed_ms INTEGER NOT NULL DEFAULT 0,
    last_window_files_per_second REAL,
    last_window_bytes_per_second REAL,
    last_window_at TEXT,
    last_decision_at TEXT,
    best_delay_ms INTEGER,
    best_files_per_second REAL,
    best_bytes_per_second REAL,
    hold_windows INTEGER NOT NULL DEFAULT 0,
    throttle_bursts INTEGER NOT NULL DEFAULT 0,
    burst_open INTEGER NOT NULL DEFAULT 0,
    cooldown_until_ms INTEGER NOT NULL DEFAULT 0,
    last_stable_delay_ms INTEGER,
    total_429 INTEGER NOT NULL DEFAULT 0,
    last_429_at_ms INTEGER NOT NULL DEFAULT 0,
    last_429_at TEXT,
    last_change_reason TEXT,
    run_start_terminal INTEGER NOT NULL DEFAULT 0,
    run_start_done INTEGER NOT NULL DEFAULT 0,
    run_start_reused INTEGER NOT NULL DEFAULT 0,
    run_started_at_ms INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS download_tuning_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    run_id INTEGER REFERENCES runs(id) ON DELETE SET NULL,
    sample_type TEXT NOT NULL,
    delay_ms INTEGER NOT NULL,
    next_delay_ms INTEGER NOT NULL,
    direction INTEGER NOT NULL,
    successes INTEGER NOT NULL DEFAULT 0,
    bytes INTEGER NOT NULL DEFAULT 0,
    elapsed_ms INTEGER NOT NULL DEFAULT 0,
    files_per_second REAL,
    bytes_per_second REAL,
    status_code INTEGER,
    note TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_download_tuning_samples_project ON download_tuning_samples(project_id,id DESC);
CREATE INDEX IF NOT EXISTS ix_project_downloads_updated ON project_downloads(project_id,updated_at,status);
CREATE INDEX IF NOT EXISTS ix_project_downloads_pending ON project_downloads(project_id,media_id) WHERE status='pending';
CREATE INDEX IF NOT EXISTS ix_project_downloads_failed_retry ON project_downloads(project_id,attempts,media_id) WHERE status='failed';
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(30,datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(34,datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(42,datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(44,datetime('now'));
'@
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $schema -ExecutionTimeoutMs 60000 | Out-Null

    # Upgrade workspaces that already received the first HF29 table definition.
    $columns=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql 'PRAGMA table_info(download_tuning);' -ExecutionTimeoutMs 5000)
    $columnNames=@($columns | ForEach-Object {[string]$_.name})
    foreach($definition in @(
        'run_start_terminal INTEGER NOT NULL DEFAULT 0',
        'run_start_done INTEGER NOT NULL DEFAULT 0',
        'run_start_reused INTEGER NOT NULL DEFAULT 0',
        'run_started_at_ms INTEGER NOT NULL DEFAULT 0',
        'last_window_delay_ms INTEGER',
        'last_window_successes INTEGER NOT NULL DEFAULT 0',
        'last_window_elapsed_ms INTEGER NOT NULL DEFAULT 0',
        'last_window_files_per_second REAL',
        'last_window_bytes_per_second REAL',
        'last_window_at TEXT',
        'last_decision_at TEXT',
        'throttle_bursts INTEGER NOT NULL DEFAULT 0',
        'burst_open INTEGER NOT NULL DEFAULT 0',
        'cooldown_until_ms INTEGER NOT NULL DEFAULT 0',
        'last_stable_delay_ms INTEGER'
    )){
        $name=($definition -split '\s+')[0]
        if($columnNames -notcontains $name){
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql ("ALTER TABLE download_tuning ADD COLUMN {0};" -f $definition) -ExecutionTimeoutMs 30000 | Out-Null
        }
    }
}


function Ensure-FsSeedOptimizationSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$SqlitePath,
        [Parameter(Mandatory=$true)][string]$DatabasePath
    )

    # HF33: Resume must not rescan the complete project_media inventory merely
    # to prove that no metadata/download task is missing. The state row records
    # a previously verified metadata coverage snapshot; the additional indexes
    # make first-time bootstrap and candidate-only download seeding predictable.
    $schema=@'
CREATE TABLE IF NOT EXISTS project_seed_state (
    project_id INTEGER PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    metadata_level INTEGER NOT NULL DEFAULT 0,
    metadata_media_count INTEGER NOT NULL DEFAULT 0,
    metadata_max_media_id INTEGER NOT NULL DEFAULT 0,
    metadata_media_id_sum INTEGER NOT NULL DEFAULT 0,
    metadata_project_updated_at TEXT,
    metadata_verified_at TEXT,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_metadata_tasks_level
    ON metadata_tasks(project_id,required_level,media_id);
-- HF53: named covering indexes for the metadata coverage-delta path. The
-- primary keys contain the same leading columns, but explicit names let the
-- exceptional Resume query force the cheap index-only anti-join even when
-- SQLite statistics on a long-lived workspace are stale.
CREATE INDEX IF NOT EXISTS ix_metadata_tasks_media_cover
    ON metadata_tasks(project_id,media_id,required_level);
CREATE INDEX IF NOT EXISTS ix_project_media_media_scan
    ON project_media(project_id,media_id);
CREATE INDEX IF NOT EXISTS ix_project_media_updated
    ON project_media(project_id,updated_at DESC,media_id);
CREATE INDEX IF NOT EXISTS ix_project_media_download_seed
    ON project_media(project_id,score DESC,media_id)
    WHERE selected=1 AND download_requested=0;
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(32,datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(52,datetime('now'));
'@
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $schema -ExecutionTimeoutMs 60000 | Out-Null
}

function Initialize-FsDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [string]$SqlitePath,
        [switch]$ShowProgress
    )
    $initializeWatch=[Diagnostics.Stopwatch]::StartNew()
    if($ShowProgress){Write-Host '        [DB 1/4] Workspace-Verzeichnisse prüfen ...' -ForegroundColor DarkGray}
    $paths = Get-FsWorkspacePaths $Workspace
    foreach ($path in @($paths.Root, $paths.Media, $paths.Review, $paths.Projects, $paths.Logs, $paths.Temp)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    if($ShowProgress){Write-Host '        [DB 2/4] sqlite3 suchen und Version prüfen ...' -ForegroundColor DarkGray}
    $sqlite = Resolve-FsSqlitePath -SqlitePath $SqlitePath -Workspace $Workspace
    $sqliteVersion=Assert-FsSqliteVersion -SqlitePath $sqlite
    if($ShowProgress){Write-Host ("        [DB 2/4] SQLite ${sqliteVersion}: $sqlite") -ForegroundColor DarkGray}

    $schema = @'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA temp_store=MEMORY;
PRAGMA wal_autocheckpoint=1000;
PRAGMA busy_timeout=60000;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS projects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    slug TEXT NOT NULL COLLATE NOCASE UNIQUE,
    profile TEXT NOT NULL,
    language TEXT NOT NULL DEFAULT 'de',
    config_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    mode TEXT NOT NULL,
    status TEXT NOT NULL,
    profile TEXT,
    parameters_json TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    error TEXT
);
CREATE INDEX IF NOT EXISTS ix_runs_project_status ON runs(project_id, status);

CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    normalized_title TEXT NOT NULL COLLATE NOCASE UNIQUE,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS project_categories (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    parent_category_id INTEGER REFERENCES categories(id),
    depth INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    continuation_json TEXT,
    member_count INTEGER NOT NULL DEFAULT 0,
    file_count INTEGER NOT NULL DEFAULT 0,
    child_count INTEGER NOT NULL DEFAULT 0,
    lease_owner TEXT,
    lease_until TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    discovered_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(project_id, category_id)
);
CREATE INDEX IF NOT EXISTS ix_project_categories_queue ON project_categories(project_id, status, depth, category_id);
CREATE INDEX IF NOT EXISTS ix_project_categories_lease ON project_categories(project_id, lease_until);

CREATE TABLE IF NOT EXISTS media (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    page_id INTEGER,
    title TEXT NOT NULL COLLATE NOCASE UNIQUE,
    normalized_title TEXT COLLATE NOCASE,
    canonical_title TEXT,
    sha1 TEXT,
    url TEXT,
    description_url TEXT,
    mime TEXT,
    media_type TEXT,
    size INTEGER,
    width INTEGER,
    height INTEGER,
    current_uploader TEXT,
    current_timestamp TEXT,
    original_uploader TEXT,
    original_timestamp TEXT,
    description TEXT,
    creator TEXT,
    license TEXT,
    license_url TEXT,
    attribution TEXT,
    latitude REAL,
    longitude REAL,
    metadata_json TEXT,
    metadata_level INTEGER NOT NULL DEFAULT 0,
    metadata_checked_level INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_media_page_id ON media(page_id) WHERE page_id IS NOT NULL AND page_id > 0;
CREATE INDEX IF NOT EXISTS ix_media_page_id_lookup ON media(page_id);
CREATE INDEX IF NOT EXISTS ix_media_normalized_title ON media(normalized_title COLLATE NOCASE) WHERE normalized_title IS NOT NULL AND normalized_title<>'';
CREATE INDEX IF NOT EXISTS ix_media_sha1 ON media(sha1);
CREATE INDEX IF NOT EXISTS ix_media_metadata ON media(metadata_level, id);


CREATE TABLE IF NOT EXISTS media_identities (
    identity_type TEXT NOT NULL CHECK(identity_type IN ('sha1','pageid','title')),
    identity_value TEXT NOT NULL COLLATE NOCASE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    source TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(identity_type, identity_value)
);
CREATE INDEX IF NOT EXISTS ix_media_identities_media ON media_identities(media_id, identity_type);


CREATE TABLE IF NOT EXISTS media_identity_conflicts (
    media_id_a INTEGER NOT NULL,
    media_id_b INTEGER NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(media_id_a,media_id_b,reason),
    CHECK(media_id_a < media_id_b)
);
CREATE INDEX IF NOT EXISTS ix_media_identity_conflicts_created ON media_identity_conflicts(created_at,media_id_a,media_id_b);

CREATE TABLE IF NOT EXISTS media_merge_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    survivor_media_id INTEGER NOT NULL,
    duplicate_media_id INTEGER NOT NULL,
    reason TEXT NOT NULL,
    merged_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_media_merge_log_survivor ON media_merge_log(survivor_media_id, id);

CREATE TABLE IF NOT EXISTS project_media (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    score INTEGER NOT NULL DEFAULT 0,
    best_source TEXT,
    selected INTEGER NOT NULL DEFAULT 1,
    download_requested INTEGER NOT NULL DEFAULT 0,
    first_seen_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(project_id, media_id)
);
CREATE INDEX IF NOT EXISTS ix_project_media_score ON project_media(project_id, selected, score DESC, media_id);

CREATE TABLE IF NOT EXISTS discoveries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    source_type TEXT NOT NULL,
    source_value TEXT,
    score INTEGER NOT NULL,
    language TEXT,
    query_text TEXT,
    origin_category_id INTEGER REFERENCES categories(id),
    parent_media_id INTEGER REFERENCES media(id),
    details_json TEXT,
    created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_discovery_identity ON discoveries(
    project_id, media_id, source_type,
    ifnull(source_value,''), ifnull(query_text,''), ifnull(parent_media_id,0)
);
CREATE INDEX IF NOT EXISTS ix_discoveries_project_media ON discoveries(project_id, media_id);

CREATE TABLE IF NOT EXISTS search_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    task_type TEXT NOT NULL,
    query_key TEXT NOT NULL,
    query_text TEXT NOT NULL,
    language TEXT,
    score INTEGER NOT NULL,
    max_results INTEGER NOT NULL,
    results_count INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'pending',
    continuation_json TEXT,
    lease_owner TEXT,
    lease_until TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(project_id, query_key)
);
CREATE INDEX IF NOT EXISTS ix_search_tasks_queue ON search_tasks(project_id, status, id);
CREATE INDEX IF NOT EXISTS ix_search_tasks_lease ON search_tasks(project_id, status, lease_until);

CREATE TABLE IF NOT EXISTS metadata_tasks (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    required_level INTEGER NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'pending',
    lease_owner TEXT,
    lease_until TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(project_id, media_id)
);
CREATE INDEX IF NOT EXISTS ix_metadata_tasks_queue ON metadata_tasks(project_id, status, media_id);

CREATE TABLE IF NOT EXISTS neighbor_tasks (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending',
    continuation_json TEXT,
    lease_owner TEXT,
    lease_until TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    api_pages INTEGER NOT NULL DEFAULT 0,
    results_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(project_id, media_id)
);
CREATE INDEX IF NOT EXISTS ix_neighbor_tasks_queue ON neighbor_tasks(project_id, status, media_id);

CREATE TABLE IF NOT EXISTS downloads (
    media_id INTEGER PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending',
    local_path TEXT,
    bytes INTEGER,
    verified_sha1 TEXT,
    historical_complete INTEGER NOT NULL DEFAULT 0,
    owner_project_id INTEGER REFERENCES projects(id),
    lease_owner TEXT,
    lease_until TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_downloads_status ON downloads(status, lease_until);
-- HF62: the rare long-download heartbeat must find the worker-owned row
-- directly instead of scanning the whole global download table.
CREATE INDEX IF NOT EXISTS ix_downloads_owner_worker_lease
    ON downloads(owner_project_id,status,lease_owner,media_id)
    WHERE status='running';
CREATE INDEX IF NOT EXISTS ix_downloads_verified_sha1
ON downloads(verified_sha1 COLLATE NOCASE, historical_complete, status, media_id)
WHERE verified_sha1 IS NOT NULL AND verified_sha1<>'';


CREATE TABLE IF NOT EXISTS download_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
    source_kind TEXT NOT NULL,
    source_path TEXT,
    status TEXT NOT NULL,
    local_path TEXT,
    local_filename TEXT,
    registered_at TEXT,
    imported_at TEXT NOT NULL,
    details_json TEXT,
    UNIQUE(media_id,source_kind,source_path,registered_at)
);
CREATE INDEX IF NOT EXISTS ix_download_history_media ON download_history(media_id,id);
CREATE INDEX IF NOT EXISTS ix_download_history_project ON download_history(project_id,id);

CREATE TABLE IF NOT EXISTS project_downloads (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending',
    lease_owner TEXT,
    lease_until TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(project_id, media_id)
);
CREATE INDEX IF NOT EXISTS ix_project_downloads_queue ON project_downloads(project_id, status, media_id);
-- HF65: narrow partial indexes for the two download-claim lanes. Pending is
-- the hot path; failed is only scanned for attempts below MaxAttempts.
CREATE INDEX IF NOT EXISTS ix_project_downloads_pending
    ON project_downloads(project_id,media_id) WHERE status='pending';
CREATE INDEX IF NOT EXISTS ix_project_downloads_failed_retry
    ON project_downloads(project_id,attempts,media_id) WHERE status='failed';
CREATE INDEX IF NOT EXISTS ix_project_downloads_updated ON project_downloads(project_id, updated_at, status);
CREATE INDEX IF NOT EXISTS ix_project_downloads_worker_lease
    ON project_downloads(project_id,status,lease_owner,media_id)
    WHERE status='running';
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(62,datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(65,datetime('now'));

-- Hotfix 31: shared, project-scoped download autotuning. Workers read the
-- current delay before every HTTP attempt and aggregate successful windows
-- without writing one telemetry row for every file.
CREATE TABLE IF NOT EXISTS download_tuning (
    project_id INTEGER PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    run_id INTEGER REFERENCES runs(id) ON DELETE SET NULL,
    enabled INTEGER NOT NULL DEFAULT 0,
    current_delay_ms INTEGER NOT NULL DEFAULT 0,
    direction INTEGER NOT NULL DEFAULT -1,
    step_ms INTEGER NOT NULL DEFAULT 20,
    window_target INTEGER NOT NULL DEFAULT 100,
    window_successes INTEGER NOT NULL DEFAULT 0,
    window_bytes INTEGER NOT NULL DEFAULT 0,
    window_started_at_ms INTEGER NOT NULL DEFAULT 0,
    previous_files_per_second REAL,
    previous_bytes_per_second REAL,
    last_window_delay_ms INTEGER,
    last_window_successes INTEGER NOT NULL DEFAULT 0,
    last_window_elapsed_ms INTEGER NOT NULL DEFAULT 0,
    last_window_files_per_second REAL,
    last_window_bytes_per_second REAL,
    last_window_at TEXT,
    last_decision_at TEXT,
    best_delay_ms INTEGER,
    best_files_per_second REAL,
    best_bytes_per_second REAL,
    hold_windows INTEGER NOT NULL DEFAULT 0,
    throttle_bursts INTEGER NOT NULL DEFAULT 0,
    burst_open INTEGER NOT NULL DEFAULT 0,
    cooldown_until_ms INTEGER NOT NULL DEFAULT 0,
    last_stable_delay_ms INTEGER,
    total_429 INTEGER NOT NULL DEFAULT 0,
    last_429_at_ms INTEGER NOT NULL DEFAULT 0,
    last_429_at TEXT,
    last_change_reason TEXT,
    run_start_terminal INTEGER NOT NULL DEFAULT 0,
    run_start_done INTEGER NOT NULL DEFAULT 0,
    run_start_reused INTEGER NOT NULL DEFAULT 0,
    run_started_at_ms INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS download_tuning_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    run_id INTEGER REFERENCES runs(id) ON DELETE SET NULL,
    sample_type TEXT NOT NULL,
    delay_ms INTEGER NOT NULL,
    next_delay_ms INTEGER NOT NULL,
    direction INTEGER NOT NULL,
    successes INTEGER NOT NULL DEFAULT 0,
    bytes INTEGER NOT NULL DEFAULT 0,
    elapsed_ms INTEGER NOT NULL DEFAULT 0,
    files_per_second REAL,
    bytes_per_second REAL,
    status_code INTEGER,
    note TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_download_tuning_samples_project ON download_tuning_samples(project_id,id DESC);


-- Hotfix 11: global, workspace-wide exclusion identities. A media item rejected
-- from any project review remains excluded when it is encountered through a
-- different keyword, category, language, neighbor search or project.
CREATE TABLE IF NOT EXISTS media_rejections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    media_id INTEGER REFERENCES media(id) ON DELETE SET NULL,
    page_id INTEGER,
    sha1 TEXT COLLATE NOCASE,
    normalized_title TEXT COLLATE NOCASE,
    reason TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'manual-review-delete',
    review_path TEXT,
    rejected_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_media_rejections_media ON media_rejections(media_id) WHERE media_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_media_rejections_page ON media_rejections(page_id) WHERE page_id IS NOT NULL AND page_id>0;
CREATE UNIQUE INDEX IF NOT EXISTS ux_media_rejections_sha1 ON media_rejections(sha1 COLLATE NOCASE) WHERE sha1 IS NOT NULL AND sha1<>'';
CREATE UNIQUE INDEX IF NOT EXISTS ux_media_rejections_title ON media_rejections(normalized_title COLLATE NOCASE) WHERE normalized_title IS NOT NULL AND normalized_title<>'';

-- One review entry per project/media. review_path points at an Explorer-friendly
-- hardlink (or copy fallback) while source_path points at the central hash store.
CREATE TABLE IF NOT EXISTS review_exports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    media_id INTEGER NOT NULL,
    sequence_no INTEGER NOT NULL,
    review_path TEXT NOT NULL COLLATE NOCASE,
    source_path TEXT NOT NULL,
    link_type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open',
    exported_at TEXT NOT NULL,
    last_seen_at TEXT,
    rejected_at TEXT,
    UNIQUE(project_id, media_id),
    UNIQUE(project_id, sequence_no),
    UNIQUE(review_path)
);
CREATE INDEX IF NOT EXISTS ix_review_exports_project_status ON review_exports(project_id,status,sequence_no);
CREATE INDEX IF NOT EXISTS ix_review_exports_media ON review_exports(media_id,status);

CREATE TABLE IF NOT EXISTS translation_concepts (
    concept_id TEXT PRIMARY KEY,
    seed_term TEXT,
    seed_key TEXT COLLATE NOCASE,
    domain TEXT,
    resolved_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_translation_concepts_seed ON translation_concepts(seed_key);

CREATE TABLE IF NOT EXISTS translations (
    concept_id TEXT NOT NULL REFERENCES translation_concepts(concept_id) ON DELETE CASCADE,
    language TEXT NOT NULL,
    term TEXT NOT NULL,
    term_key TEXT NOT NULL COLLATE NOCASE,
    term_type TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 50,
    created_at TEXT NOT NULL,
    PRIMARY KEY(concept_id, language, term_key, term_type)
);
CREATE INDEX IF NOT EXISTS ix_translations_language ON translations(language, concept_id, priority DESC);

CREATE TABLE IF NOT EXISTS api_gate (
    name TEXT PRIMARY KEY,
    next_at_ms INTEGER NOT NULL DEFAULT 0,
    adaptive_delay_ms INTEGER NOT NULL DEFAULT 0,
    last_throttle_at_ms INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS named_locks (
    name TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    lease_until TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    run_id INTEGER REFERENCES runs(id) ON DELETE CASCADE,
    stage TEXT,
    level TEXT NOT NULL,
    message TEXT NOT NULL,
    details_json TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_events_project_time ON events(project_id, id DESC);

CREATE TABLE IF NOT EXISTS migration_sources (
    source_path TEXT PRIMARY KEY,
    imported_at TEXT NOT NULL,
    stats_json TEXT
);

INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(11, datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(12, datetime('now'));
INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(13, datetime('now'));
'@
    if($ShowProgress){Write-Host '        [DB 3/4] Tabellen und Indizes prüfen/anlegen ...' -ForegroundColor DarkGray}
    $schemaWatch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $paths.Database -Sql $schema -ProgressLabel $(if($ShowProgress){'Tabellen und Standardindizes prüfen/anlegen'}else{$null}) | Out-Null
    Ensure-FsDownloadTuningSchema -SqlitePath $sqlite -DatabasePath $paths.Database
    Ensure-FsSeedOptimizationSchema -SqlitePath $sqlite -DatabasePath $paths.Database
    if($ShowProgress){Write-Host ("        [DB 3/4] Tabellen und Standardindizes bereit nach {0}." -f (Format-FsProgressDuration $schemaWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray}

    # V5.0.13: Separate "checked" level from imported metadata level.
    # Existing V4 imports may carry metadata_level=2 although the record has
    # never been refreshed against the current Commons API.
    $mediaColumns=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $paths.Database -Query -Sql 'PRAGMA table_info(media);')
    if(-not(@($mediaColumns.name) -contains 'metadata_checked_level')){
        if($ShowProgress){Write-Host '        [DB 3/4] Metadaten-Prüfstatus ergänzen (einmalige, verlustfreie Schema-Erweiterung) ...' -ForegroundColor DarkGray}
        Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $paths.Database -Sql 'ALTER TABLE media ADD COLUMN metadata_checked_level INTEGER NOT NULL DEFAULT 0;' | Out-Null
    }
    # Hotfix 10: Existing workspaces need the adaptive API-gate columns once.
    $apiGateColumns=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $paths.Database -Query -Sql 'PRAGMA table_info(api_gate);')
    if(-not(@($apiGateColumns.name) -contains 'adaptive_delay_ms')){
        Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $paths.Database -Sql 'ALTER TABLE api_gate ADD COLUMN adaptive_delay_ms INTEGER NOT NULL DEFAULT 0;' | Out-Null
    }
    if(-not(@($apiGateColumns.name) -contains 'last_throttle_at_ms')){
        Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $paths.Database -Sql 'ALTER TABLE api_gate ADD COLUMN last_throttle_at_ms INTEGER NOT NULL DEFAULT 0;' | Out-Null
    }

    $metadataIndexWatch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $paths.Database -Sql 'CREATE INDEX IF NOT EXISTS ix_media_metadata_check ON media(metadata_checked_level,metadata_level,id);' -ProgressLabel $(if($ShowProgress){'Metadaten-Prüfindex prüfen/anlegen'}else{$null}) | Out-Null
    # PRAGMA optimize is intentionally not executed on every startup. On the
    # user's 58k-media workspace it added minutes although the relevant
    # indexes already existed. SQLite maintains the indexes without it; a
    # future maintenance command can run ANALYZE/optimize explicitly.
    if($ShowProgress){Write-Host ("        [DB 3/4] Metadaten-Prüfindex bereit nach {0}." -f (Format-FsProgressDuration $metadataIndexWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray}

    if($ShowProgress){Write-Host '        [DB 4/4] Schema-Migrationen und offene Medienkonflikte prüfen ...' -ForegroundColor DarkGray}
    $identityWatch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-FsMediaIdentityMigration -SqlitePath $sqlite -DatabasePath $paths.Database -ShowProgress:$ShowProgress
    if($ShowProgress){Write-Host ("        [DB 4/4] Medienidentitäten geprüft in {0}." -f (Format-FsProgressDuration $identityWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray}
    if($ShowProgress){Write-Host ("        [DB] bereit nach {0}" -f (Format-FsProgressDuration $initializeWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray}
    return [pscustomobject]@{ Paths = $paths; SqlitePath = $sqlite }
}

function Get-FsProjectByName {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $rows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql (
        'SELECT * FROM projects WHERE name=' + (ConvertTo-FsSqlLiteral $Name) + ' COLLATE NOCASE LIMIT 1;'
    )
    if (@($rows).Count -eq 0) { return $null }
    return $rows[0]
}

function Save-FsProject {
    param(
        [Parameter(Mandatory = $true)][string]$SqlitePath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Slug,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][string]$ConfigJson
    )
    $existing = Get-FsProjectByName -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Name $Name
    if ($null -ne $existing) { $Slug = [string]$existing.slug }
    else {
        $slugRows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql ('SELECT id FROM projects WHERE slug=' + (ConvertTo-FsSqlLiteral $Slug) + ' COLLATE NOCASE LIMIT 1;')
        if (@($slugRows).Count -gt 0) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $suffix = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,8) }
            finally { $sha.Dispose() }
            $Slug = ($Slug.TrimEnd('-') + '-' + $suffix)
        }
    }
    $now = Get-FsUtcNowText
    $sql = @"
INSERT INTO projects(name,slug,profile,language,config_json,created_at,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $Name),$(ConvertTo-FsSqlLiteral $Slug),$(ConvertTo-FsSqlLiteral $Profile),$(ConvertTo-FsSqlLiteral $Language),$(ConvertTo-FsSqlLiteral $ConfigJson),$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now))
ON CONFLICT(name) DO UPDATE SET
    profile=excluded.profile,
    language=excluded.language,
    config_json=excluded.config_json,
    updated_at=excluded.updated_at;
SELECT * FROM projects WHERE name=$(ConvertTo-FsSqlLiteral $Name) COLLATE NOCASE LIMIT 1;
"@
    $rows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query
    return $rows[-1]
}

function New-FsRun {
    param(
        [string]$SqlitePath,[string]$DatabasePath,[int]$ProjectId,[string]$Mode,[string]$Profile,[string]$ParametersJson
    )
    $now = Get-FsUtcNowText
    $sql = @"
INSERT INTO runs(project_id,mode,status,profile,parameters_json,started_at)
VALUES($ProjectId,$(ConvertTo-FsSqlLiteral $Mode),'running',$(ConvertTo-FsSqlLiteral $Profile),$(ConvertTo-FsSqlLiteral $ParametersJson),$(ConvertTo-FsSqlLiteral $now));
SELECT last_insert_rowid() AS id;
"@
    $rows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query
    return [int]$rows[-1].id
}

function Complete-FsRun {
    param([string]$SqlitePath,[string]$DatabasePath,[int]$RunId,[string]$Status='completed',[string]$Error)
    $now = Get-FsUtcNowText
    $sql = "UPDATE runs SET status=$(ConvertTo-FsSqlLiteral $Status), finished_at=$(ConvertTo-FsSqlLiteral $now), error=$(ConvertTo-FsSqlLiteral $Error) WHERE id=$RunId;"
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql | Out-Null
}

function Stop-FsStaleRuns {
    param([string]$SqlitePath,[string]$DatabasePath,[int]$ProjectId,[string]$Reason='Voriger Prozess ist nicht mehr aktiv; beim nächsten exklusiven Start bereinigt.')
    $now = Get-FsUtcNowText
    $rows = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
UPDATE runs
SET status='abandoned',finished_at=$(ConvertTo-FsSqlLiteral $now),error=$(ConvertTo-FsSqlLiteral $Reason)
WHERE project_id=$ProjectId AND status='running';
SELECT changes() changed;
"@)
    if ($rows.Count -eq 0) { return 0 }
    return [int]$rows[-1].changed
}

function Test-FsRunActive {
    param([string]$SqlitePath,[string]$DatabasePath,[int]$RunId)
    $rows = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT status FROM runs WHERE id=$RunId LIMIT 1;")
    return ($rows.Count -gt 0 -and [string]$rows[0].status -eq 'running')
}

function Open-FsProjectRunLock {
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [int]$ProjectId=0,
        [Parameter(Mandatory=$true)][string]$ProjectName
    )
    $lockDirectory = Join-Path (Resolve-FsAbsolutePath $Workspace) '.locks'
    if (-not (Test-Path -LiteralPath $lockDirectory)) { New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null }

    # The lock key is derived from the project name so it can be acquired before
    # database initialization and before a new project has received its ID.
    $normalizedName=$ProjectName.Trim().ToLowerInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $token=(($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedName)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,20)
    }
    finally { $sha.Dispose() }
    $lockPath = Join-Path $lockDirectory ("project-{0}.run.lock" -f $token)
    try {
        $stream = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }
    catch [IO.IOException] {
        throw "Für Projekt '$ProjectName' läuft bereits eine FindSeries-Pipeline in diesem Workspace. Beende zuerst den vorhandenen Prozess. Lock: $lockPath"
    }
    try {
        $payload = [ordered]@{ pid=$PID; machine=$env:COMPUTERNAME; project_id=$ProjectId; project=$ProjectName; started_at=(Get-FsUtcNowText) } | ConvertTo-Json -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $stream.SetLength(0)
        $stream.Position=0
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush()
        return [pscustomobject]@{ Path=$lockPath; Stream=$stream; Owner=$payload }
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Close-FsProjectRunLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try { if ($null -ne $Lock.Stream) { $Lock.Stream.Dispose() } } catch {}
    try { if ($Lock.Path -and (Test-Path -LiteralPath ([string]$Lock.Path))) { Remove-Item -LiteralPath ([string]$Lock.Path) -Force -ErrorAction SilentlyContinue } } catch {}
}



function Open-FsDownloadGateState {
    param(
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [ValidateRange(1000,60000)][int]$WaitTimeoutMs=15000
    )
    $statePath=$DatabasePath+'.download-gate'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        try{
            $stream=[IO.File]::Open($statePath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            return [pscustomobject]@{Path=$statePath;Stream=$stream}
        }catch [IO.IOException]{
            if($watch.ElapsedMilliseconds -ge $WaitTimeoutMs){
                throw "Download-Gate-Datei konnte nach $([Math]::Round($watch.Elapsed.TotalSeconds,1)) s nicht gesperrt werden: $statePath"
            }
            Start-Sleep -Milliseconds (20+(Get-Random -Minimum 0 -Maximum 31))
        }
    }
}


function Read-FsDownloadGateState {
    param($GateLock)
    $nextAt=[long]0
    $cooldownUntil=[long]0
    $recoverySlotsRemaining=0
    $recoverySpacingMs=3000
    $stream=$GateLock.Stream
    try{
        if($stream.Length -gt 0){
            $stream.Position=0
            $bytes=New-Object byte[] ([int]$stream.Length)
            [void]$stream.Read($bytes,0,$bytes.Length)
            $json=[Text.Encoding]::UTF8.GetString($bytes)
            if(-not[string]::IsNullOrWhiteSpace($json)){
                $state=$json|ConvertFrom-Json
                if($null -ne $state.next_at_ms){$nextAt=[long]$state.next_at_ms}
                if($null -ne $state.cooldown_until_ms){$cooldownUntil=[long]$state.cooldown_until_ms}
                if($null -ne $state.recovery_slots_remaining){$recoverySlotsRemaining=[Math]::Max(0,[int]$state.recovery_slots_remaining)}
                if($null -ne $state.recovery_spacing_ms){$recoverySpacingMs=[Math]::Max(0,[int]$state.recovery_spacing_ms)}
            }
        }
    }catch{}
    return [pscustomobject]@{
        NextAtMs=$nextAt
        CooldownUntilMs=$cooldownUntil
        RecoverySlotsRemaining=$recoverySlotsRemaining
        RecoverySpacingMs=$recoverySpacingMs
    }
}

function Write-FsDownloadGateState {
    param(
        $GateLock,
        [long]$NextAtMs,
        [long]$CooldownUntilMs,
        [int]$RecoverySlotsRemaining=0,
        [int]$RecoverySpacingMs=3000
    )
    $payload=[ordered]@{
        next_at_ms=$NextAtMs
        cooldown_until_ms=$CooldownUntilMs
        recovery_slots_remaining=[Math]::Max(0,$RecoverySlotsRemaining)
        recovery_spacing_ms=[Math]::Max(0,$RecoverySpacingMs)
        updated_at=(Get-FsUtcNowText)
        pid=$PID
    }|ConvertTo-Json -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $stream=$GateLock.Stream
    $stream.SetLength(0)
    $stream.Position=0
    $stream.Write($bytes,0,$bytes.Length)
    $stream.Flush()
}

function Close-FsDownloadGateState {
    param($GateLock)
    if($null -ne $GateLock -and $null -ne $GateLock.Stream){
        try{$GateLock.Stream.Dispose()}catch{}
    }
}

function Acquire-FsDownloadApiSlot {
    param(
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [int]$DelayMs,
        [ValidateRange(0,60000)][int]$RecoverySpacingMs=3000
    )
    $delay=[Math]::Max(0,$DelayMs)
    $gateLock=Open-FsDownloadGateState -DatabasePath $DatabasePath
    try{
        $state=Read-FsDownloadGateState -GateLock $gateLock
        $now=Get-FsUnixMilliseconds
        $cooldownReady=[long]$state.CooldownUntilMs
        $slotAt=[Math]::Max([long]$now,[Math]::Max([long]$state.NextAtMs,$cooldownReady))

        # HF50: A cooldown creates a finite one-shot recovery wave. Only the
        # first N requests after the pause are staggered. Earlier versions kept
        # applying the 15-second spread forever, which limited four workers to
        # roughly one file every 15 seconds even at DelayMs=0.
        $remaining=[Math]::Max(0,[int]$state.RecoverySlotsRemaining)
        $storedRecoverySpacing=[Math]::Max(0,[int]$state.RecoverySpacingMs)
        if($storedRecoverySpacing -le 0){$storedRecoverySpacing=$RecoverySpacingMs}
        $isRecoverySlot=($remaining -gt 0)
        if($isRecoverySlot){$remaining--}

        $spacingAfterThisSlot=if($remaining -gt 0){
            [Math]::Max($delay,$storedRecoverySpacing)
        }else{
            $delay
        }
        $nextAt=$slotAt+[long]$spacingAfterThisSlot
        Write-FsDownloadGateState -GateLock $gateLock -NextAtMs $nextAt -CooldownUntilMs $cooldownReady -RecoverySlotsRemaining $remaining -RecoverySpacingMs $storedRecoverySpacing
    }finally{Close-FsDownloadGateState -GateLock $gateLock}

    $wait=[Math]::Max([long]0,$slotAt-(Get-FsUnixMilliseconds))
    if($wait -gt 0){Start-Sleep -Milliseconds ([int][Math]::Min([int]::MaxValue,$wait))}
    return [pscustomobject]@{
        WaitMs=$wait
        EffectiveDelayMs=$delay
        RecoverySlot=$isRecoverySlot
        RecoverySlotsRemaining=$remaining
        RecoverySpacingMs=$(if($isRecoverySlot){$storedRecoverySpacing}else{0})
    }
}

function Set-FsDownloadApiCooldown {
    param(
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [int]$Seconds,
        [ValidateRange(1,64)][int]$RecoverySlots=4,
        [ValidateRange(0,60000)][int]$RecoverySpacingMs=3000
    )
    $secondsSafe=[Math]::Max(1,$Seconds)
    $target=(Get-FsUnixMilliseconds)+([long]$secondsSafe*1000)+(Get-Random -Minimum 0 -Maximum 1001)
    $gateLock=Open-FsDownloadGateState -DatabasePath $DatabasePath
    try{
        $state=Read-FsDownloadGateState -GateLock $gateLock
        $cooldown=[Math]::Max([long]$state.CooldownUntilMs,[long]$target)

        # Reset old/faulty gate reservations to the cooldown boundary and arm
        # exactly one recovery slot per configured worker.
        Write-FsDownloadGateState -GateLock $gateLock -NextAtMs $cooldown -CooldownUntilMs $cooldown -RecoverySlotsRemaining $RecoverySlots -RecoverySpacingMs $RecoverySpacingMs
    }finally{Close-FsDownloadGateState -GateLock $gateLock}
    return $target
}

function Acquire-FsApiSlot {
    param(
        [string]$SqlitePath,[string]$DatabasePath,[string]$GateName,[int]$DelayMs
    )
    $nowMs = Get-FsUnixMilliseconds
    $baseDelayMs=[Math]::Max(0,$DelayMs)
    $gate = ConvertTo-FsSqlLiteral $GateName
    # After a throttle response the gate raises its spacing by 250 ms. If no
    # new throttle occurred for 15 minutes it decays one step and starts a new
    # stable interval until it reaches the configured baseline. All state changes happen in the existing
    # gate transaction, so adaptive throttling adds no extra sqlite3 process.
    $decayAfterMs=900000
    $decayStepMs=250
    $sql = @"
BEGIN IMMEDIATE;
INSERT OR IGNORE INTO api_gate(name,next_at_ms,adaptive_delay_ms,last_throttle_at_ms)
VALUES($gate,0,0,0);
UPDATE api_gate
SET adaptive_delay_ms=CASE
        WHEN adaptive_delay_ms<=$baseDelayMs THEN 0
        WHEN last_throttle_at_ms>0 AND ($nowMs-last_throttle_at_ms)>=$decayAfterMs
            THEN MAX($baseDelayMs,adaptive_delay_ms-$decayStepMs)
        ELSE adaptive_delay_ms
    END,
    last_throttle_at_ms=CASE
        WHEN adaptive_delay_ms>$baseDelayMs
         AND last_throttle_at_ms>0
         AND ($nowMs-last_throttle_at_ms)>=$decayAfterMs
            THEN $nowMs
        ELSE last_throttle_at_ms
    END
WHERE name=$gate;
UPDATE api_gate
SET next_at_ms=(CASE WHEN next_at_ms>$nowMs THEN next_at_ms ELSE $nowMs END)+
    CASE WHEN adaptive_delay_ms>$baseDelayMs THEN adaptive_delay_ms ELSE $baseDelayMs END
WHERE name=$gate
RETURNING
    next_at_ms-(CASE WHEN adaptive_delay_ms>$baseDelayMs THEN adaptive_delay_ms ELSE $baseDelayMs END) AS slot_at_ms,
    CASE WHEN adaptive_delay_ms>$baseDelayMs THEN adaptive_delay_ms ELSE $baseDelayMs END AS effective_delay_ms;
COMMIT;
"@
    $rows = @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query)
    if ($rows.Count -eq 0) { return [pscustomobject]@{WaitMs=0;EffectiveDelayMs=$baseDelayMs} }
    $slot = [long]$rows[-1].slot_at_ms
    $effective=[int]$rows[-1].effective_delay_ms
    $wait = [Math]::Max(0,$slot - (Get-FsUnixMilliseconds))
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min([int]::MaxValue, $wait)) }
    return [pscustomobject]@{WaitMs=$wait;EffectiveDelayMs=$effective}
}

function Set-FsApiCooldown {
    param([string]$SqlitePath,[string]$DatabasePath,[string]$GateName,[int]$Seconds,[int]$BaseDelayMs=0)
    $secondsSafe=[Math]::Max(1,$Seconds)
    $nowMs=Get-FsUnixMilliseconds
    $target=$nowMs+([long]$secondsSafe*1000)+(Get-Random -Minimum 0 -Maximum 1001)
    $base=[Math]::Max(0,$BaseDelayMs)
    $step=250
    $maximum=5000
    $gate=ConvertTo-FsSqlLiteral $GateName
    $adaptiveExpression=if($GateName -eq 'commons-download'){'0'}else{"MIN($maximum,MAX($base,adaptive_delay_ms)+$step)"}
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
INSERT OR IGNORE INTO api_gate(name,next_at_ms,adaptive_delay_ms,last_throttle_at_ms)
VALUES($gate,0,0,0);
UPDATE api_gate
SET next_at_ms=CASE WHEN next_at_ms>$target THEN next_at_ms ELSE $target END,
    adaptive_delay_ms=$adaptiveExpression,
    last_throttle_at_ms=$nowMs
WHERE name=$gate;
COMMIT;
"@ | Out-Null
    return $target
}


function Acquire-FsNamedLock {
    param(
        [string]$SqlitePath,[string]$DatabasePath,[string]$Name,[string]$Owner,
        [int]$LeaseSeconds=300,[int]$WaitSeconds=300
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $now = Get-FsUtcNowText
        $lease = [DateTime]::UtcNow.AddSeconds($LeaseSeconds).ToString('o')
        $sql = @"
BEGIN IMMEDIATE;
DELETE FROM named_locks WHERE name=$(ConvertTo-FsSqlLiteral $Name) AND lease_until<=$(ConvertTo-FsSqlLiteral $now);
INSERT OR IGNORE INTO named_locks(name,owner,lease_until,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $Name),$(ConvertTo-FsSqlLiteral $Owner),$(ConvertTo-FsSqlLiteral $lease),$(ConvertTo-FsSqlLiteral $now));
SELECT owner,lease_until FROM named_locks WHERE name=$(ConvertTo-FsSqlLiteral $Name);
COMMIT;
"@
        $rows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query
        if (@($rows).Count -gt 0 -and [string]$rows[-1].owner -eq $Owner) { return $true }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Release-FsNamedLock {
    param([string]$SqlitePath,[string]$DatabasePath,[string]$Name,[string]$Owner)
    $sql = "DELETE FROM named_locks WHERE name=$(ConvertTo-FsSqlLiteral $Name) AND owner=$(ConvertTo-FsSqlLiteral $Owner);"
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql | Out-Null
}

function Write-FsEvent {
    param(
        [string]$SqlitePath,[string]$DatabasePath,[Nullable[int]]$ProjectId,[Nullable[int]]$RunId,
        [string]$Stage,[string]$Level='info',[string]$Message,$Details
    )
    $detailsJson = if ($null -ne $Details) { $Details | ConvertTo-Json -Depth 20 -Compress } else { $null }
    $now = Get-FsUtcNowText
    $sql = @"
INSERT INTO events(project_id,run_id,stage,level,message,details_json,created_at)
VALUES($(ConvertTo-FsSqlLiteral $ProjectId),$(ConvertTo-FsSqlLiteral $RunId),$(ConvertTo-FsSqlLiteral $Stage),$(ConvertTo-FsSqlLiteral $Level),$(ConvertTo-FsSqlLiteral $Message),$(ConvertTo-FsSqlLiteral $detailsJson),$(ConvertTo-FsSqlLiteral $now));
"@
    try{
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -BusyRetries 3 -ExecutionTimeoutMs 30000 | Out-Null
    }catch{
        # HF57: diagnostics must never turn a recoverable worker/database
        # incident into the fatal error that ends the whole run.
        if($_.Exception.Message -match '(?i)(disk I/O error|SQLITE_IOERR|I/O error \(10\)|SQLite-Ausführungszeit|SQLite-Schreibsperre|database is locked|database is busy)'){
            Write-Warning ("Ereignisprotokoll vorübergehend nicht schreibbar: {0}" -f $_.Exception.Message)
            return
        }
        throw
    }
}

function Get-FsProjectSummary {
    param([string]$SqlitePath,[string]$DatabasePath,[int]$ProjectId)
    $sql = @"
SELECT
 (SELECT COUNT(*) FROM project_media WHERE project_id=$ProjectId) AS media_count,
 (SELECT COUNT(*) FROM project_categories WHERE project_id=$ProjectId) AS category_count,
 (SELECT COUNT(*) FROM project_categories WHERE project_id=$ProjectId AND status='done') AS categories_done,
 (SELECT COUNT(*) FROM project_categories WHERE project_id=$ProjectId AND status='pending') AS categories_pending,
 (SELECT COUNT(*) FROM project_categories WHERE project_id=$ProjectId AND status='running') AS categories_running,
 (SELECT COUNT(*) FROM project_categories WHERE project_id=$ProjectId AND status='failed') AS categories_failed,
 (SELECT COUNT(*) FROM project_categories WHERE project_id=$ProjectId AND status='skipped') AS categories_skipped,
 (SELECT COUNT(*) FROM search_tasks WHERE project_id=$ProjectId AND status='done') AS searches_done,
 (SELECT COUNT(*) FROM search_tasks WHERE project_id=$ProjectId AND status='pending') AS searches_pending,
 (SELECT COUNT(*) FROM search_tasks WHERE project_id=$ProjectId AND status='running') AS searches_running,
 (SELECT COUNT(*) FROM search_tasks WHERE project_id=$ProjectId AND status='failed') AS searches_failed,
 (SELECT COUNT(*) FROM search_tasks WHERE project_id=$ProjectId AND status='skipped') AS searches_skipped,
 (SELECT COUNT(*) FROM metadata_tasks WHERE project_id=$ProjectId AND status='done') AS metadata_done,
 (SELECT COUNT(*) FROM metadata_tasks WHERE project_id=$ProjectId AND status='pending') AS metadata_pending,
 (SELECT COUNT(*) FROM metadata_tasks WHERE project_id=$ProjectId AND status='running') AS metadata_running,
 (SELECT COUNT(*) FROM metadata_tasks WHERE project_id=$ProjectId AND status='failed') AS metadata_failed,
 (SELECT COUNT(*) FROM metadata_tasks WHERE project_id=$ProjectId AND status='skipped') AS metadata_skipped,
 (SELECT COUNT(*) FROM neighbor_tasks WHERE project_id=$ProjectId AND status='done') AS neighbors_done,
 (SELECT COUNT(*) FROM neighbor_tasks WHERE project_id=$ProjectId AND status='pending') AS neighbors_pending,
 (SELECT COUNT(*) FROM neighbor_tasks WHERE project_id=$ProjectId AND status='running') AS neighbors_running,
 (SELECT COUNT(*) FROM neighbor_tasks WHERE project_id=$ProjectId AND status='failed') AS neighbors_failed,
 (SELECT COUNT(*) FROM neighbor_tasks WHERE project_id=$ProjectId AND status='skipped') AS neighbors_skipped,
 (SELECT COUNT(*) FROM project_downloads WHERE project_id=$ProjectId AND status='done') AS downloads_done,
 (SELECT COUNT(*) FROM project_downloads WHERE project_id=$ProjectId AND status='reused') AS downloads_reused,
 (SELECT COUNT(*) FROM project_downloads WHERE project_id=$ProjectId AND status='pending') AS downloads_pending,
 (SELECT COUNT(*) FROM project_downloads WHERE project_id=$ProjectId AND status='running') AS downloads_running,
 (SELECT COUNT(*) FROM project_downloads WHERE project_id=$ProjectId AND status='failed') AS downloads_failed,
 (SELECT COUNT(*) FROM project_downloads WHERE project_id=$ProjectId AND status='skipped') AS downloads_skipped;
"@
    $rows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query
    return $rows[0]
}

Export-ModuleMember -Function *-Fs*
