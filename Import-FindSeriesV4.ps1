# V5.0.5 one-time, restartable high-performance migration from FindSeries V4.x/V4.5 into V5 SQLite.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [string]$Workspace,
    [string]$SqlitePath,
    [ValidateSet('Reference','Copy','Move','Skip')][string]$ImageMode='Reference',

    # Fast is the optimized default for this one-time, reproducible import.
    [ValidateSet('Fast','Balanced','Safe')][string]$ImportMode='Fast',

    # A value of 0 uses the selected profile. Explicit values override it.
    [ValidateRange(0,100000)][int]$BatchRecords=0,
    [ValidateRange(0,4096)][int]$SQLiteCacheMB=0,
    [ValidateRange(0,16384)][int]$SQLiteMmapMB=0,
    [ValidateSet('Auto','Wal','Memory','Off')][string]$SQLiteJournal='Auto',
    [ValidateSet('Auto','Full','Normal','Off')][string]$SQLiteSynchronous='Auto',
    [ValidateRange(0,100000)][int]$ProgressEvery=0,

    [switch]$CompactMetadata,
    [switch]$Force
)

$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $PSScriptRoot

function Resolve-ImportSettings {
    $profile = switch($ImportMode){
        'Safe' {
            @{ BatchRecords=5000; ProgressEvery=2500; CacheMB=256; MmapMB=512; Journal='WAL'; Synchronous='FULL'; Locking='NORMAL'; WalAutoCheckpoint=1000 }
        }
        'Balanced' {
            @{ BatchRecords=10000; ProgressEvery=5000; CacheMB=512; MmapMB=1024; Journal='WAL'; Synchronous='NORMAL'; Locking='NORMAL'; WalAutoCheckpoint=50000 }
        }
        default {
            # Fast remains restartable for a normal Ctrl+C/application stop because WAL transactions stay atomic.
            # It is less durable only against an operating-system crash or power loss during the import.
            @{ BatchRecords=25000; ProgressEvery=5000; CacheMB=1024; MmapMB=2048; Journal='WAL'; Synchronous='OFF'; Locking='EXCLUSIVE'; WalAutoCheckpoint=100000 }
        }
    }

    if($BatchRecords -gt 0){$profile.BatchRecords=$BatchRecords}
    if($ProgressEvery -gt 0){$profile.ProgressEvery=$ProgressEvery}
    if($SQLiteCacheMB -gt 0){$profile.CacheMB=$SQLiteCacheMB}
    if($SQLiteMmapMB -gt 0){$profile.MmapMB=$SQLiteMmapMB}
    if($SQLiteJournal -ne 'Auto'){$profile.Journal=$SQLiteJournal.ToUpperInvariant()}
    if($SQLiteSynchronous -ne 'Auto'){$profile.Synchronous=$SQLiteSynchronous.ToUpperInvariant()}

    # Large metadata JSON records make Details batches considerably heavier than Discovery batches.
    $profile.DetailBatchRecords=[Math]::Max(1000,[Math]::Min(20000,[int][Math]::Ceiling($profile.BatchRecords/5.0)))
    $profile.ManifestBatchRecords=[Math]::Max(2000,[Math]::Min(30000,[int][Math]::Ceiling($profile.BatchRecords/2.0)))
    $profile.RegistryBatchRecords=$profile.ManifestBatchRecords
    return [pscustomobject]$profile
}

$script:ImportSettings=Resolve-ImportSettings
$script:BatchRecords=[int]$script:ImportSettings.BatchRecords
$script:ProgressEvery=[int]$script:ImportSettings.ProgressEvery
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1') -Force

$sourceRoot=Resolve-FsAbsolutePath $Source
if(-not(Test-Path -LiteralPath $sourceRoot -PathType Container)){throw "Altes Arbeitsverzeichnis nicht gefunden: $sourceRoot"}
$init=Initialize-FsDatabase -Workspace $Workspace -SqlitePath $SqlitePath
$paths=$init.Paths;$sqlite=$init.SqlitePath;$db=$paths.Database
$sourceKey=$sourceRoot.ToLowerInvariant()
$owner="migration-$PID-$([Guid]::NewGuid().ToString('N'))"
$script:FastBatchPath=$null
$script:FastBatchWriter=$null
$script:FastBatchRecords=0
$script:CurrentBatchStartLine=0L

function Get-OldProp {
    param($Object,[string[]]$Names,$Default=$null)
    if($null -eq $Object){return $Default}
    foreach($name in $Names){
        if($Object -is [System.Collections.IDictionary]){
            if($Object.Contains($name) -and $null -ne $Object[$name]){return $Object[$name]}
            continue
        }
        $property=$Object.PSObject.Properties[$name]
        if($null -ne $property -and $null -ne $property.Value){return $property.Value}
    }
    return $Default
}

function Convert-OldBool {
    param($Value)
    if($Value -is [bool]){return $Value}
    return ([string]$Value -match '^(?i:true|1|yes|ja)$')
}

function Convert-OldInt64 {
    param($Value,[long]$Default=0)
    $result=0L
    if($null -ne $Value -and [long]::TryParse(([string]$Value),[ref]$result)){return $result}
    return $Default
}

function Read-JsonSafe {
    param([string]$Path)
    try{return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json)}
    catch{try{return(Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}catch{return $null}}
}

function Write-MigrationError {
    param([string]$Path,[long]$LineNumber,[string]$Message)
    $logPath=Join-Path $paths.Logs 'migration-errors.log'
    $text="$Path line ${LineNumber}: $Message"
    [IO.File]::AppendAllText($logPath,$text+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
}

function Initialize-MigrationCheckpointTable {
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
CREATE TABLE IF NOT EXISTS migration_checkpoints (
    source_root TEXT NOT NULL,
    item_key TEXT NOT NULL,
    line_number INTEGER NOT NULL DEFAULT 0,
    completed INTEGER NOT NULL DEFAULT 0,
    details_json TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(source_root,item_key)
);
CREATE INDEX IF NOT EXISTS ix_migration_checkpoints_source ON migration_checkpoints(source_root,completed,item_key);
"@ | Out-Null
}

function Get-MigrationCheckpoint {
    param([string]$ItemKey)
    $rows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql (
        "SELECT line_number,completed,details_json,updated_at FROM migration_checkpoints WHERE source_root="+
        (ConvertTo-FsSqlLiteral $sourceKey)+" AND item_key="+(ConvertTo-FsSqlLiteral $ItemKey)+" LIMIT 1;"
    ))
    if($rows.Count -eq 0){return [pscustomobject]@{line_number=0L;completed=0;details_json=$null;updated_at=$null}}
    return $rows[0]
}

function Clear-AbandonedMigrationLock {
    $rows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT owner FROM named_locks WHERE name='v4-migration' LIMIT 1;")
    if($rows.Count -eq 0){return}
    $lockOwner=[string]$rows[0].owner
    if($lockOwner -match '^migration-(?<processId>\d+)-'){
        $processId=[int]$matches.processId
        $processExists=$false
        try{$null=Get-Process -Id $processId -ErrorAction Stop;$processExists=$true}catch{}
        if(-not $processExists){
            Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql (
                "DELETE FROM named_locks WHERE name='v4-migration' AND owner="+(ConvertTo-FsSqlLiteral $lockOwner)+";"
            ) | Out-Null
            Write-Host "Verwaisten Migrations-Lock entfernt: $lockOwner" -ForegroundColor Yellow
        }
    }
}

function Start-FastBatch {
    param([long]$StartLine=0)
    if($null -ne $script:FastBatchWriter){throw 'Interner Fehler: SQL-Batch ist bereits geöffnet.'}
    $script:FastBatchPath=Join-Path $paths.Temp ("migration-batch-$PID-$([Guid]::NewGuid().ToString('N')).sql")
    $encoding=New-Object Text.UTF8Encoding($false)
    $script:FastBatchWriter=New-Object IO.StreamWriter($script:FastBatchPath,$false,$encoding,1048576)
    $script:FastBatchWriter.NewLine="`n"
    $script:FastBatchWriter.WriteLine('.timeout 60000')
    $script:FastBatchWriter.WriteLine('.bail on')
    $cacheKiB=[long]$script:ImportSettings.CacheMB*1024L
    $mmapBytes=[long]$script:ImportSettings.MmapMB*1024L*1024L
    $script:FastBatchWriter.WriteLine('PRAGMA foreign_keys=ON;')
    $script:FastBatchWriter.WriteLine('PRAGMA journal_mode='+$script:ImportSettings.Journal+';')
    $script:FastBatchWriter.WriteLine('PRAGMA synchronous='+$script:ImportSettings.Synchronous+';')
    $script:FastBatchWriter.WriteLine('PRAGMA locking_mode='+$script:ImportSettings.Locking+';')
    $script:FastBatchWriter.WriteLine('PRAGMA temp_store=MEMORY;')
    $script:FastBatchWriter.WriteLine('PRAGMA cache_size=-'+$cacheKiB+';')
    $script:FastBatchWriter.WriteLine('PRAGMA mmap_size='+$mmapBytes+';')
    $script:FastBatchWriter.WriteLine('PRAGMA wal_autocheckpoint='+$script:ImportSettings.WalAutoCheckpoint+';')
    $script:FastBatchWriter.WriteLine('PRAGMA defer_foreign_keys=ON;')
    $script:FastBatchWriter.WriteLine('BEGIN IMMEDIATE;')
    $script:FastBatchRecords=0
    $script:CurrentBatchStartLine=$StartLine
}

function Add-FastSql {
    param([string]$Sql)
    if([string]::IsNullOrWhiteSpace($Sql)){return}
    if($null -eq $script:FastBatchWriter){Start-FastBatch}
    $script:FastBatchWriter.WriteLine($Sql)
}

function Invoke-FsSqlFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$sqlite
    $psi.Arguments='"'+$db.Replace('"','""')+'" -batch -bail'
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
    $fileStream=$null
    try{
        if(-not $process.Start()){throw 'sqlite3-Prozess konnte nicht gestartet werden.'}
        $fileStream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{
            $fileStream.CopyTo($process.StandardInput.BaseStream,1048576)
            $process.StandardInput.Close()
        }
        catch{
            try{$process.StandardInput.Close()}catch{}
            try{$stderr=$process.StandardError.ReadToEnd()}catch{$stderr=$null}
            $message=if(-not [string]::IsNullOrWhiteSpace($stderr)){$stderr.Trim()}else{$_.Exception.Message}
            throw "SQLite-Importfehler: $message`nSQL-Batch bleibt zur Diagnose erhalten: $Path"
        }
        $stdout=$process.StandardOutput.ReadToEnd()
        $stderr=$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode=$process.ExitCode
        if($exitCode -ne 0){
            $message=if(-not [string]::IsNullOrWhiteSpace($stderr)){$stderr.Trim()}else{"sqlite3 ExitCode $exitCode"}
            throw "SQLite-Importfehler: $message`nSQL-Batch bleibt zur Diagnose erhalten: $Path"
        }
    }
    finally{
        if($null -ne $fileStream){$fileStream.Dispose()}
        if($null -ne $process){
            if(-not $process.HasExited){try{$process.Kill()}catch{}}
            $process.Dispose()
        }
    }
}

function Complete-FastBatch {
    param(
        [Parameter(Mandatory=$true)][string]$ItemKey,
        [long]$LineNumber,
        [bool]$Completed,
        $Details=$null
    )
    if($null -eq $script:FastBatchWriter){Start-FastBatch -StartLine $LineNumber}
    $now=Get-FsUtcNowText
    $detailsJson=if($null -eq $Details){$null}else{$Details|ConvertTo-Json -Depth 8 -Compress}
    $script:FastBatchWriter.WriteLine(@"
INSERT INTO migration_checkpoints(source_root,item_key,line_number,completed,details_json,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $sourceKey),$(ConvertTo-FsSqlLiteral $ItemKey),$LineNumber,$(if($Completed){1}else{0}),$(ConvertTo-FsSqlLiteral $detailsJson),$(ConvertTo-FsSqlLiteral $now))
ON CONFLICT(source_root,item_key) DO UPDATE SET
 line_number=MAX(migration_checkpoints.line_number,excluded.line_number),
 completed=MAX(migration_checkpoints.completed,excluded.completed),
 details_json=excluded.details_json,
 updated_at=excluded.updated_at;
COMMIT;
"@)
    $script:FastBatchWriter.Flush()
    $script:FastBatchWriter.Dispose()
    $script:FastBatchWriter=$null
    try{
        Invoke-FsSqlFile -Path $script:FastBatchPath
        Remove-Item -LiteralPath $script:FastBatchPath -Force -ErrorAction SilentlyContinue
        $script:FastBatchPath=$null
    }
    catch{
        $script:FastBatchPath=$null
        throw
    }
}

function Abort-FastBatch {
    if($null -ne $script:FastBatchWriter){
        try{$script:FastBatchWriter.Dispose()}catch{}
        $script:FastBatchWriter=$null
    }
    if($script:FastBatchPath -and (Test-Path -LiteralPath $script:FastBatchPath)){
        Remove-Item -LiteralPath $script:FastBatchPath -Force -ErrorAction SilentlyContinue
    }
    $script:FastBatchPath=$null
    $script:FastBatchRecords=0
}

function Get-ProgressText {
    param([long]$CurrentLine,[long]$ResumeLine,[Diagnostics.Stopwatch]$Clock,[double]$Percent,[long]$Bad)
    $processed=[Math]::Max(0,$CurrentLine-$ResumeLine)
    $rate=if($Clock.Elapsed.TotalSeconds -gt 0){$processed/$Clock.Elapsed.TotalSeconds}else{0}
    $etaText='--:--:--'
    if($Percent -gt 0.1 -and $Percent -lt 100 -and $Clock.Elapsed.TotalSeconds -gt 0){
        $remainingSeconds=$Clock.Elapsed.TotalSeconds*((100.0-$Percent)/$Percent)
        if($remainingSeconds -lt [TimeSpan]::MaxValue.TotalSeconds){$etaText=([TimeSpan]::FromSeconds($remainingSeconds)).ToString('d\.hh\:mm\:ss')}
    }
    return "Zeile $CurrentLine | $([Math]::Round($Percent,1))% | $([Math]::Round($rate,1))/s | Fehler $Bad | ETA $etaText"
}

function Import-JsonLinesFast {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][scriptblock]$Handler,
        [int]$ProjectNumber=0,
        [int]$ProjectCount=0,
        [int]$EffectiveBatchRecords=$script:BatchRecords
    )
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){
        return [pscustomobject]@{Ok=0L;Bad=0L;Skipped=0L;ResumedFrom=0L;Completed=$true;Missing=$true}
    }
    $itemKey=("jsonl|"+$Path.ToLowerInvariant())
    $checkpoint=Get-MigrationCheckpoint -ItemKey $itemKey
    if([int]$checkpoint.completed -eq 1 -and -not $Force){
        Write-Host "        [$Stage] bereits vollständig importiert" -ForegroundColor DarkGray
        return [pscustomobject]@{Ok=0L;Bad=0L;Skipped=[long]$checkpoint.line_number;ResumedFrom=[long]$checkpoint.line_number;Completed=$true;Missing=$false}
    }
    [long]$resumeLine=if($Force){0}else{[long]$checkpoint.line_number}
    [long]$lineNo=0;[long]$ok=0;[long]$bad=0;[long]$batchLines=0
    $stream=$null;$reader=$null
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $lastConsoleLine=0L
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true,65536,$false)
        if($resumeLine -gt 0){Write-Host "        [$Stage] Fortsetzung ab Zeile $($resumeLine+1)" -ForegroundColor Cyan}
        Start-FastBatch -StartLine $resumeLine
        while($null -ne ($line=$reader.ReadLine())){
            $lineNo++
            if($lineNo -le $resumeLine){continue}
            $batchLines++
            if(-not [string]::IsNullOrWhiteSpace($line)){
                try{
                    $record=$line|ConvertFrom-Json
                    &$Handler $record
                    $ok++
                }
                catch{
                    $bad++
                    Write-MigrationError -Path $Path -LineNumber $lineNo -Message $_.Exception.Message
                }
            }
            if($batchLines -ge $EffectiveBatchRecords){
                Complete-FastBatch -ItemKey $itemKey -LineNumber $lineNo -Completed $false -Details @{stage=$Stage;ok=$ok;bad=$bad}
                Start-FastBatch -StartLine $lineNo
                $batchLines=0
            }
            if(($lineNo-$lastConsoleLine) -ge $script:ProgressEvery){
                $lastConsoleLine=$lineNo
                $percent=if($stream.Length -gt 0){[Math]::Min(100.0,($stream.Position*100.0)/$stream.Length)}else{100.0}
                $status=Get-ProgressText -CurrentLine $lineNo -ResumeLine $resumeLine -Clock $clock -Percent $percent -Bad $bad
                $activity=if($ProjectCount -gt 0){"V4-Import [$ProjectNumber/$ProjectCount] $Stage"}else{"V4-Import $Stage"}
                Write-Progress -Activity $activity -Status $status -PercentComplete $percent
                Write-Host "        [$Stage] $status" -ForegroundColor DarkGray
            }
        }
        Complete-FastBatch -ItemKey $itemKey -LineNumber $lineNo -Completed $true -Details @{stage=$Stage;ok=$ok;bad=$bad}
        $completedActivity=if($ProjectCount -gt 0){"V4-Import [$ProjectNumber/$ProjectCount] $Stage"}else{"V4-Import $Stage"}
        Write-Progress -Activity $completedActivity -Completed
        return [pscustomobject]@{Ok=$ok;Bad=$bad;Skipped=$resumeLine;ResumedFrom=$resumeLine;Completed=$true;Missing=$false}
    }
    catch{
        Abort-FastBatch
        throw
    }
    finally{
        if($null -ne $reader){$reader.Dispose()}elseif($null -ne $stream){$stream.Dispose()}
        $clock.Stop()
    }
}

function Import-CsvFast {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][scriptblock]$Handler,
        [int]$EffectiveBatchRecords=$script:BatchRecords
    )
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{Ok=0L;Skipped=0L;Completed=$true;Missing=$true}}
    $itemKey=("csv|"+$Path.ToLowerInvariant())
    $checkpoint=Get-MigrationCheckpoint -ItemKey $itemKey
    if([int]$checkpoint.completed -eq 1 -and -not $Force){
        Write-Host "        [$Stage] bereits vollständig importiert" -ForegroundColor DarkGray
        return [pscustomobject]@{Ok=0L;Skipped=[long]$checkpoint.line_number;Completed=$true;Missing=$false}
    }
    [long]$resumeRow=if($Force){0}else{[long]$checkpoint.line_number}
    [long]$rowNo=0;[long]$ok=0;[long]$batchRows=0
    try{
        Start-FastBatch -StartLine $resumeRow
        Import-Csv -LiteralPath $Path | ForEach-Object {
            $rowNo++
            if($rowNo -gt $resumeRow){
                &$Handler $_
                $ok++;$batchRows++
                if($batchRows -ge $EffectiveBatchRecords){
                    Complete-FastBatch -ItemKey $itemKey -LineNumber $rowNo -Completed $false -Details @{stage=$Stage;ok=$ok}
                    Start-FastBatch -StartLine $rowNo
                    $batchRows=0
                }
                if(($rowNo % $script:ProgressEvery) -eq 0){Write-Host "        [$Stage] $rowNo Zeilen" -ForegroundColor DarkGray}
            }
        }
        Complete-FastBatch -ItemKey $itemKey -LineNumber $rowNo -Completed $true -Details @{stage=$Stage;ok=$ok}
        return [pscustomobject]@{Ok=$ok;Skipped=$resumeRow;Completed=$true;Missing=$false}
    }
    catch{Abort-FastBatch;throw}
}

function Import-StateCategoriesFast {
    param([string]$RunDir,$State,[int]$ProjectId,[string]$Now)
    $itemKey=("state-categories|"+$RunDir.ToLowerInvariant())
    $checkpoint=Get-MigrationCheckpoint -ItemKey $itemKey
    if([int]$checkpoint.completed -eq 1 -and -not $Force){return}
    [long]$index=0;[long]$resume=if($Force){0}else{[long]$checkpoint.line_number};[long]$batchRows=0
    try{
        Start-FastBatch -StartLine $resume
        foreach($raw in @((Get-OldProp $State @('VisitedCategories') @()))){
            $index++
            if($index -le $resume){continue}
            $title=Normalize-FsCategoryTitle ([string]$raw);if(-not $title){continue}
            $norm=$title.ToLowerInvariant()
            Add-FastSql "INSERT OR IGNORE INTO categories(title,normalized_title,created_at) VALUES($(ConvertTo-FsSqlLiteral $title),$(ConvertTo-FsSqlLiteral $norm),$(ConvertTo-FsSqlLiteral $Now));"
            Add-FastSql "INSERT OR IGNORE INTO project_categories(project_id,category_id,depth,status,discovered_at,updated_at) SELECT $ProjectId,id,0,'done',$(ConvertTo-FsSqlLiteral $Now),$(ConvertTo-FsSqlLiteral $Now) FROM categories WHERE normalized_title=$(ConvertTo-FsSqlLiteral $norm);"
            $batchRows++
            if($batchRows -ge $script:BatchRecords){Complete-FastBatch -ItemKey $itemKey -LineNumber $index -Completed $false;Start-FastBatch -StartLine $index;$batchRows=0}
        }
        Complete-FastBatch -ItemKey $itemKey -LineNumber $index -Completed $true
    }catch{Abort-FastBatch;throw}
}

function Test-V4SuccessfulDownloadStatus {
    param([string]$Status)
    if([string]::IsNullOrWhiteSpace($Status)){return $false}
    return $Status.Trim().ToLowerInvariant() -in @(
        'geladen','fortgesetzt','vorhanden',
        'downloaded','resumed','existing','present','success','successful','complete','done'
    )
}

function Get-V4IdentityValues {
    param($Record)
    $result=@{Title=$null;PageId=0L;Sha1=$null}
    $title=[string](Get-OldProp $Record @('CanonicalTitle','Title','FileTitle','Name'))
    if(-not [string]::IsNullOrWhiteSpace($title)){$result.Title=Normalize-FsFileTitle $title}
    $result.PageId=Convert-OldInt64 (Get-OldProp $Record @('PageId','PageID','pageid'))
    $sha=[string](Get-OldProp $Record @('Sha1','SHA1','sha1'))
    if($sha -match '^[0-9a-fA-F]{40}$'){$result.Sha1=$sha.ToLowerInvariant()}
    $keys=New-Object Collections.Generic.List[string]
    foreach($name in @('Key','RegistryKey','GlobalRegistryKey','Keys','RegistryKeys')){
        $value=Get-OldProp $Record @($name)
        foreach($item in @($value)){if(-not [string]::IsNullOrWhiteSpace([string]$item)){$keys.Add(([string]$item).Trim())}}
    }
    foreach($key in $keys){
        if(-not $result.Sha1 -and $key -match '^(?i:sha1):(?<value>[0-9a-f]{40})$'){$result.Sha1=$matches.value.ToLowerInvariant();continue}
        if($result.PageId -le 0 -and $key -match '^(?i:pageid):(?<value>\d+)$'){$result.PageId=[long]$matches.value;continue}
        if(-not $result.Title -and $key -match '^(?i:title):(?<value>.+)$'){$result.Title=Normalize-FsFileTitle $matches.value}
    }
    return $result
}

function ConvertTo-V4MediaRecord {
    param($SourceRecord,[int]$MetadataLevel=0)
    $identity=Get-V4IdentityValues $SourceRecord
    $title=$identity.Title
    if(-not $title){
        if($identity.PageId -gt 0){$title="File:Imported pageid $($identity.PageId)"}
        elseif($identity.Sha1){$title="File:Imported sha1 $($identity.Sha1)"}
        else{return $null}
    }
    return [pscustomobject]@{
        PageId=$identity.PageId
        Title=$title
        CanonicalTitle=[string](Get-OldProp $SourceRecord @('CanonicalTitle','Title','FileTitle') $title)
        Sha1=$identity.Sha1
        Url=[string](Get-OldProp $SourceRecord @('Url','OriginalUrl'))
        DescriptionUrl=[string](Get-OldProp $SourceRecord @('DescriptionUrl','CommonsUrl'))
        Mime=[string](Get-OldProp $SourceRecord @('Mime','MimeType'))
        MediaType=[string](Get-OldProp $SourceRecord @('MediaType'))
        Size=Convert-OldInt64 (Get-OldProp $SourceRecord @('Size','Bytes'))
        Width=[int](Convert-OldInt64 (Get-OldProp $SourceRecord @('Width')))
        Height=[int](Convert-OldInt64 (Get-OldProp $SourceRecord @('Height')))
        CurrentUploader=[string](Get-OldProp $SourceRecord @('CurrentUploader','Uploader'))
        CurrentTimestamp=[string](Get-OldProp $SourceRecord @('CurrentTimestamp','Timestamp'))
        OriginalUploader=[string](Get-OldProp $SourceRecord @('OriginalUploader'))
        OriginalTimestamp=[string](Get-OldProp $SourceRecord @('OriginalUploadTimestamp','OriginalTimestamp'))
        Description=[string](Get-OldProp $SourceRecord @('Description'))
        Creator=[string](Get-OldProp $SourceRecord @('Creator'))
        License=[string](Get-OldProp $SourceRecord @('License'))
        LicenseUrl=[string](Get-OldProp $SourceRecord @('LicenseUrl'))
        Attribution=[string](Get-OldProp $SourceRecord @('Attribution'))
        Latitude=Get-OldProp $SourceRecord @('Latitude')
        Longitude=Get-OldProp $SourceRecord @('Longitude')
        MetadataJson=if($MetadataLevel -gt 0 -and -not $CompactMetadata){$SourceRecord|ConvertTo-Json -Depth 40 -Compress}else{$null}
        MetadataLevel=$MetadataLevel
    }
}

function Get-MigratedDestinationPath {
    param($Record,[string]$OldPath,[string]$BaseDirectory)
    if([string]::IsNullOrWhiteSpace($OldPath)){return $null}
    if(-not[IO.Path]::IsPathRooted($OldPath)){$OldPath=Join-Path $BaseDirectory $OldPath}
    $sha=[string]$Record.Sha1
    if([string]::IsNullOrWhiteSpace($sha)){$sha=Get-FsSha256Text ([string]$Record.Title)}
    if([string]::IsNullOrWhiteSpace($sha) -or $sha.Length -lt 2){return $null}
    $sub=Join-Path $paths.Media $sha.Substring(0,2)
    return Join-Path $sub ([IO.Path]::GetFileName($OldPath))
}

function Resolve-MigratedMediaPath {
    param($Record,[string]$OldPath,[string]$BaseDirectory)
    if($ImageMode -eq 'Skip' -or [string]::IsNullOrWhiteSpace($OldPath)){return $null}
    if(-not[IO.Path]::IsPathRooted($OldPath)){$OldPath=Join-Path $BaseDirectory $OldPath}
    $oldFull=[IO.Path]::GetFullPath($OldPath)
    $dest=Get-MigratedDestinationPath -Record $Record -OldPath $oldFull -BaseDirectory $BaseDirectory
    if($ImageMode -eq 'Reference'){
        if(Test-Path -LiteralPath $oldFull -PathType Leaf){return $oldFull}
        if($dest -and (Test-Path -LiteralPath $dest -PathType Leaf)){return [IO.Path]::GetFullPath($dest)}
        return $null
    }
    # Restart safety for Move/Copy: a prior interrupted batch may already have moved the file.
    if($dest -and (Test-Path -LiteralPath $dest -PathType Leaf)){return [IO.Path]::GetFullPath($dest)}
    if(-not(Test-Path -LiteralPath $oldFull -PathType Leaf)){return $null}
    $sub=Split-Path -Parent $dest
    if(-not(Test-Path -LiteralPath $sub)){New-Item -ItemType Directory -Path $sub -Force|Out-Null}
    if($ImageMode -eq 'Copy'){Copy-Item -LiteralPath $oldFull -Destination $dest -Force}
    else{Move-Item -LiteralPath $oldFull -Destination $dest -Force}
    return [IO.Path]::GetFullPath($dest)
}

function Add-DownloadImportSql {
    param(
        $SourceRecord,$MediaRecord,[Nullable[int]]$ProjectId,[string]$SourceKind,
        [string]$SourcePath,[string]$BaseDirectory,[string]$Now
    )
    $status=[string](Get-OldProp $SourceRecord @('DownloadStatus','Status'))
    if(-not(Test-V4SuccessfulDownloadStatus $status)){return}
    $oldPath=[string](Get-OldProp $SourceRecord @('LocalPath','Path'))
    $path=Resolve-MigratedMediaPath -Record $MediaRecord -OldPath $oldPath -BaseDirectory $BaseDirectory
    $bytes=if($path){(Get-Item -LiteralPath $path).Length}else{Convert-OldInt64 (Get-OldProp $SourceRecord @('Size','Bytes'))}
    $dbStatus=if($path){'done'}else{'historical'}
    $lookup=Get-FsMediaLookupSqlExpression $MediaRecord
    $registered=[string](Get-OldProp $SourceRecord @('RegisteredAt','DownloadedAt','GeneratedAt') $Now)
    $filename=[string](Get-OldProp $SourceRecord @('LocalFilename'))
    if(-not $filename -and $path){$filename=[IO.Path]::GetFileName($path)}
    $details=if($CompactMetadata){$null}else{$SourceRecord|ConvertTo-Json -Depth 30 -Compress}
    $ownerSql=if($null -ne $ProjectId){[string][int]$ProjectId}else{'NULL'}
    Add-FastSql @"
INSERT INTO downloads(media_id,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,created_at,updated_at)
SELECT id,$(ConvertTo-FsSqlLiteral $dbStatus),$(ConvertTo-FsSqlLiteral $path),$bytes,$(ConvertTo-FsSqlLiteral $MediaRecord.Sha1),1,$ownerSql,$(ConvertTo-FsSqlLiteral $Now),$(ConvertTo-FsSqlLiteral $Now) FROM media WHERE id=$lookup
ON CONFLICT(media_id) DO UPDATE SET
 status=CASE WHEN downloads.status='done' THEN 'done' WHEN excluded.status='done' THEN 'done' ELSE 'historical' END,
 local_path=COALESCE(downloads.local_path,excluded.local_path),
 bytes=MAX(COALESCE(downloads.bytes,0),COALESCE(excluded.bytes,0)),
 verified_sha1=COALESCE(excluded.verified_sha1,downloads.verified_sha1),
 historical_complete=1,
 owner_project_id=COALESCE(downloads.owner_project_id,excluded.owner_project_id),
 updated_at=excluded.updated_at;
INSERT OR IGNORE INTO download_history(media_id,project_id,source_kind,source_path,status,local_path,local_filename,registered_at,imported_at,details_json)
SELECT id,$ownerSql,$(ConvertTo-FsSqlLiteral $SourceKind),$(ConvertTo-FsSqlLiteral $SourcePath),$(ConvertTo-FsSqlLiteral $status),$(ConvertTo-FsSqlLiteral $path),$(ConvertTo-FsSqlLiteral $filename),$(ConvertTo-FsSqlLiteral $registered),$(ConvertTo-FsSqlLiteral $Now),$(ConvertTo-FsSqlLiteral $details)
FROM media WHERE id=$lookup;
"@
    if($null -ne $ProjectId){
        Add-FastSql "INSERT INTO project_downloads(project_id,media_id,status,updated_at) SELECT $([int]$ProjectId),id,'reused',$(ConvertTo-FsSqlLiteral $Now) FROM media WHERE id=$lookup ON CONFLICT(project_id,media_id) DO UPDATE SET status='reused',updated_at=excluded.updated_at;"
    }
}

function Restore-FsOperationalDatabaseMode {
    try{
        Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
PRAGMA locking_mode=NORMAL;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA wal_checkpoint(TRUNCATE);
PRAGMA optimize;
"@ | Out-Null
    }
    catch{
        Write-Warning "SQLite-Betriebsmodus konnte nicht vollständig zurückgesetzt werden: $($_.Exception.Message)"
    }
}

Initialize-MigrationCheckpointTable
if($Force){
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql (
        "DELETE FROM migration_sources WHERE source_path="+(ConvertTo-FsSqlLiteral $sourceKey)+";"+
        "DELETE FROM migration_checkpoints WHERE source_root="+(ConvertTo-FsSqlLiteral $sourceKey)+";"
    ) | Out-Null
}
$known=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT source_path FROM migration_sources WHERE source_path=$(ConvertTo-FsSqlLiteral $sourceKey);")
if($known.Count -gt 0 -and -not $Force){throw 'Dieses Verzeichnis wurde bereits vollständig importiert. Verwende -Force für einen erneuten idempotenten Import.'}
Clear-AbandonedMigrationLock
if(-not(Acquire-FsNamedLock -SqlitePath $sqlite -DatabasePath $db -Name 'v4-migration' -Owner $owner -LeaseSeconds 86400 -WaitSeconds 30)){throw 'Eine andere Migration läuft bereits.'}

try{
    $stateFiles=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter 'state.json' -ErrorAction SilentlyContinue|Where-Object{$_.FullName -notlike "$($paths.Root)*"}|Sort-Object FullName)
    Write-Host "V4-Läufe gefunden: $($stateFiles.Count)" -ForegroundColor Cyan
    Write-Host ("Importprofil: {0} | Bilder: {1} | Restart-Checkpoints: aktiv | CompactMetadata: {2}" -f $ImportMode,$ImageMode,[bool]$CompactMetadata) -ForegroundColor Gray
    Write-Host ("Batches: Discoveries {0:N0} | Details {1:N0} | Manifest/Registry {2:N0}" -f $script:BatchRecords,$script:ImportSettings.DetailBatchRecords,$script:ImportSettings.ManifestBatchRecords) -ForegroundColor Gray
    Write-Host ("SQLite: journal={0} | synchronous={1} | locking={2} | Cache={3} MB | mmap={4} MB" -f $script:ImportSettings.Journal,$script:ImportSettings.Synchronous,$script:ImportSettings.Locking,$script:ImportSettings.CacheMB,$script:ImportSettings.MmapMB) -ForegroundColor Gray
    if($script:ImportSettings.Journal -eq 'OFF'){
        Write-Warning 'SQLiteJournal=Off ist maximal schnell, aber ein Abbruch kann die Datenbank beschädigen. Für restartfähige Importe ist das Standardprofil Fast mit WAL empfohlen.'
    }elseif($script:ImportSettings.Synchronous -eq 'OFF'){
        Write-Host 'Fast-Modus: Ctrl+C/Anwendungsabbruch bleibt transaktional restartfähig; Stromausfall oder Betriebssystemabsturz während des Imports ist weniger abgesichert.' -ForegroundColor Yellow
    }
    $totalRuns=0;$projectIds=@{};$projectIdByName=@{};$totalMedia=0;$totalBad=0

    foreach($stateFile in $stateFiles){
        $runDir=$stateFile.Directory.FullName
        $state=Read-JsonSafe $stateFile.FullName
        if($null -eq $state){Write-Warning "state.json unlesbar: $($stateFile.FullName)";continue}
        $name=[string](Get-OldProp $state @('Project','Topic') $stateFile.Directory.Name)
        if([string]::IsNullOrWhiteSpace($name)){$name=$stateFile.Directory.Name}
        $slug=ConvertTo-FsSlug $name
        $migratedConfig=@{MigratedFrom=$runDir;OriginalVersion=(Get-OldProp $state @('Version') 4);Profile='Migrated'}|ConvertTo-Json -Compress
        $project=Save-FsProject -SqlitePath $sqlite -DatabasePath $db -Name $name -Slug $slug -Profile 'Balanced' -Language 'de' -ConfigJson $migratedConfig
        $currentProjectId=[int]$project.id;$projectIds[$currentProjectId]=$true;$projectIdByName[$name.Trim().ToLowerInvariant()]=$currentProjectId;$totalRuns++
        Write-Host "[$totalRuns/$($stateFiles.Count)] $name <- $runDir" -ForegroundColor Gray
        $now=Get-FsUtcNowText

        $categoryCsv=Join-Path $runDir 'categories.csv'
        if(Test-Path -LiteralPath $categoryCsv){
            $null=Import-CsvFast -Path $categoryCsv -Stage 'Kategorien' -Handler {
                param($row)
                $title=Normalize-FsCategoryTitle ([string](Get-OldProp $row @('Category','Title')));if(-not $title){return}
                $norm=$title.ToLowerInvariant();$depth=[int](Convert-OldInt64 (Get-OldProp $row @('Depth')))
                $status=if(Convert-OldBool (Get-OldProp $row @('Visited','Processed') $false)){'done'}else{'pending'}
                Add-FastSql "INSERT OR IGNORE INTO categories(title,normalized_title,created_at) VALUES($(ConvertTo-FsSqlLiteral $title),$(ConvertTo-FsSqlLiteral $norm),$(ConvertTo-FsSqlLiteral $now));"
                Add-FastSql "INSERT INTO project_categories(project_id,category_id,depth,status,discovered_at,updated_at) SELECT $currentProjectId,id,$depth,$(ConvertTo-FsSqlLiteral $status),$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now) FROM categories WHERE normalized_title=$(ConvertTo-FsSqlLiteral $norm) ON CONFLICT(project_id,category_id) DO UPDATE SET depth=MIN(project_categories.depth,excluded.depth),status=CASE WHEN project_categories.status='done' OR excluded.status='done' THEN 'done' ELSE project_categories.status END,updated_at=excluded.updated_at;"
            }
        }else{Import-StateCategoriesFast -RunDir $runDir -State $state -ProjectId $currentProjectId -Now $now}

        $discPath=Join-Path $runDir 'discoveries.jsonl'
        $discStats=Import-JsonLinesFast -Path $discPath -Stage 'Discoveries' -ProjectNumber $totalRuns -ProjectCount $stateFiles.Count -EffectiveBatchRecords $script:BatchRecords -Handler {
            param($r)
            $record=ConvertTo-V4MediaRecord $r 0;if($null -eq $record){return}
            $score=[int](Convert-OldInt64 (Get-OldProp $r @('Score')))
            $source=[string](Get-OldProp $r @('SourceType','OriginType') 'migration')
            Add-FastSql (Get-FsMediaInsertSql $record $now)
            Add-FastSql (Get-FsProjectMediaSql $currentProjectId $record $score $source $now)
            $discoveryDetails=if($CompactMetadata){$null}else{$r}
            Add-FastSql (Get-FsDiscoverySql $currentProjectId $record $source ([string](Get-OldProp $r @('SourceValue','OriginSeed'))) $score ([string](Get-OldProp $r @('Language'))) ([string](Get-OldProp $r @('Query','MatchedTerm'))) $null $null $discoveryDetails $now)
        }
        $totalBad+=$discStats.Bad

        $detailsPath=Join-Path $runDir 'details.jsonl'
        $detailBatch=[int]$script:ImportSettings.DetailBatchRecords
        $detailStats=Import-JsonLinesFast -Path $detailsPath -Stage 'Details' -ProjectNumber $totalRuns -ProjectCount $stateFiles.Count -EffectiveBatchRecords $detailBatch -Handler {
            param($r)
            $record=ConvertTo-V4MediaRecord $r 2;if($null -eq $record){return}
            Add-FastSql (Get-FsMediaInsertSql $record $now)
        }
        $totalBad+=$detailStats.Bad

        $manifest=Join-Path $runDir 'manifest.jsonl'
        $manifestBatch=[int]$script:ImportSettings.ManifestBatchRecords
        $manifestStats=Import-JsonLinesFast -Path $manifest -Stage 'Manifest' -ProjectNumber $totalRuns -ProjectCount $stateFiles.Count -EffectiveBatchRecords $manifestBatch -Handler {
            param($r)
            $record=ConvertTo-V4MediaRecord $r 1;if($null -eq $record){return}
            $score=[int](Convert-OldInt64 (Get-OldProp $r @('Score')))
            Add-FastSql (Get-FsMediaInsertSql $record $now)
            Add-FastSql (Get-FsProjectMediaSql $currentProjectId $record $score 'migration-manifest' $now)
            Add-DownloadImportSql -SourceRecord $r -MediaRecord $record -ProjectId $currentProjectId -SourceKind 'v4-manifest' -SourcePath $manifest -BaseDirectory $runDir -Now $now
        }
        $totalBad+=$manifestStats.Bad
        Write-FsEvent -SqlitePath $sqlite -DatabasePath $db -ProjectId $currentProjectId -RunId $null -Stage 'migration' -Level 'info' -Message "V4-Lauf importiert: $runDir" -Details @{discoveries=$discStats;details=$detailStats;manifest=$manifestStats}
    }

    $registryFiles=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter 'download-registry.jsonl' -ErrorAction SilentlyContinue|Sort-Object FullName -Unique)
    foreach($registryFile in $registryFiles){
        Write-Host "Globale Download-Historie importieren: $($registryFile.FullName)" -ForegroundColor Gray
        $registryStats=Import-JsonLinesFast -Path $registryFile.FullName -Stage 'Download-Registry' -EffectiveBatchRecords ([int]$script:ImportSettings.RegistryBatchRecords) -Handler {
            param($r)
            $status=[string](Get-OldProp $r @('DownloadStatus','Status'))
            if(-not(Test-V4SuccessfulDownloadStatus $status)){return}
            $record=ConvertTo-V4MediaRecord $r 1;if($null -eq $record){return}
            $registryNow=Get-FsUtcNowText
            $registryProjectId=$null
            $oldProjectName=[string](Get-OldProp $r @('Project','Topic'))
            if(-not[string]::IsNullOrWhiteSpace($oldProjectName)){
                $projectKey=$oldProjectName.Trim().ToLowerInvariant()
                if($projectIdByName.ContainsKey($projectKey)){$registryProjectId=[Nullable[int]]([int]$projectIdByName[$projectKey])}
                else{
                    # Project creation is deliberately done outside SQL batches by checking once and caching.
                    $registryProject=Get-FsProjectByName -SqlitePath $sqlite -DatabasePath $db -Name $oldProjectName
                    if($null -eq $registryProject){
                        $registryConfig=@{MigratedFrom=$registryFile.FullName;RegistryOnly=$true;Profile='Migrated'}|ConvertTo-Json -Compress
                        $registryProject=Save-FsProject -SqlitePath $sqlite -DatabasePath $db -Name $oldProjectName -Slug (ConvertTo-FsSlug $oldProjectName) -Profile 'Balanced' -Language 'de' -ConfigJson $registryConfig
                    }
                    $registryProjectId=[Nullable[int]]([int]$registryProject.id)
                    $projectIds[[int]$registryProject.id]=$true
                    $projectIdByName[$projectKey]=[int]$registryProject.id
                }
            }
            Add-FastSql (Get-FsMediaInsertSql $record $registryNow)
            Add-DownloadImportSql -SourceRecord $r -MediaRecord $record -ProjectId $registryProjectId -SourceKind 'v4-global-registry' -SourcePath $registryFile.FullName -BaseDirectory $registryFile.Directory.FullName -Now $registryNow
        }
        $totalBad+=$registryStats.Bad
    }

    $translationFiles=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter 'translations-long.csv' -ErrorAction SilentlyContinue|Sort-Object FullName -Unique)
    foreach($file in $translationFiles){
        Write-Host "Translations importieren: $($file.FullName)" -ForegroundColor Gray
        $null=Import-CsvFast -Path $file.FullName -Stage 'Translations' -Handler {
            param($row)
            $qid=[string](Get-OldProp $row @('ConceptId','Qid'));$term=[string](Get-OldProp $row @('Term','Value'));$lang=[string](Get-OldProp $row @('Language') 'und')
            if($qid -notmatch '^Q\d+$' -or [string]::IsNullOrWhiteSpace($term)){return}
            $type=[string](Get-OldProp $row @('TermType','Type') 'label');$priority=[int](Convert-OldInt64 (Get-OldProp $row @('Priority') 50) 50)
            $seed=[string](Get-OldProp $row @('SeedTerms','SeedTerm'))
            $seedKey=if([string]::IsNullOrWhiteSpace($seed)){$null}else{$seed.ToLowerInvariant()}
            $translationNow=Get-FsUtcNowText
            Add-FastSql "INSERT OR IGNORE INTO translation_concepts(concept_id,seed_term,seed_key,domain,resolved_at) VALUES($(ConvertTo-FsSqlLiteral $qid),$(ConvertTo-FsSqlLiteral $seed),$(ConvertTo-FsSqlLiteral $seedKey),$(ConvertTo-FsSqlLiteral (Get-OldProp $row @('Domains','Domain'))),$(ConvertTo-FsSqlLiteral $translationNow));"
            Add-FastSql "INSERT OR IGNORE INTO translations(concept_id,language,term,term_key,term_type,priority,created_at) VALUES($(ConvertTo-FsSqlLiteral $qid),$(ConvertTo-FsSqlLiteral $lang),$(ConvertTo-FsSqlLiteral $term),$(ConvertTo-FsSqlLiteral $term.ToLowerInvariant()),$(ConvertTo-FsSqlLiteral $type),$priority,$(ConvertTo-FsSqlLiteral $translationNow));"
        }
    }

    Write-Host 'Medienidentitäten zusammenführen ...' -ForegroundColor Cyan
    $merged=Repair-FsMediaIdentityConflicts -SqlitePath $sqlite -DatabasePath $db -MaxPairs 100000
    $mediaRows=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM media;'
    $identityRows=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM media_identities;'
    foreach($currentProjectId in $projectIds.Keys){$countRows=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT COUNT(*) count FROM project_media WHERE project_id=$currentProjectId;";$totalMedia+=[int]$countRows[0].count}
    $stats=@{runs=$totalRuns;projects=$projectIds.Count;media_sum_by_project=$totalMedia;global_media=[int]$mediaRows[0].count;identities=[int]$identityRows[0].count;merged_media=$merged;bad_lines=$totalBad;image_mode=$ImageMode;compact_metadata=[bool]$CompactMetadata;import_mode=$ImportMode;batch_records=$script:BatchRecords;detail_batch_records=$script:ImportSettings.DetailBatchRecords;manifest_batch_records=$script:ImportSettings.ManifestBatchRecords;sqlite_cache_mb=$script:ImportSettings.CacheMB;sqlite_mmap_mb=$script:ImportSettings.MmapMB;sqlite_journal=$script:ImportSettings.Journal;sqlite_synchronous=$script:ImportSettings.Synchronous;source=$sourceRoot}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "INSERT OR REPLACE INTO migration_sources(source_path,imported_at,stats_json) VALUES($(ConvertTo-FsSqlLiteral $sourceKey),$(ConvertTo-FsSqlLiteral (Get-FsUtcNowText)),$(ConvertTo-FsSqlLiteral ($stats|ConvertTo-Json -Compress)));"|Out-Null
    Restore-FsOperationalDatabaseMode
    Write-Host "Migration abgeschlossen: $($projectIds.Count) Projects aus $totalRuns V4-Läufen" -ForegroundColor Green
    Write-Host "Globale Medien: $($mediaRows[0].count); Identitäten: $($identityRows[0].count); zusammengeführt: $merged; beschädigte Zeilen: $totalBad" -ForegroundColor Gray
    Write-Host "Workspace: $($paths.Root)" -ForegroundColor Gray
}
finally{
    Abort-FastBatch
    try{Release-FsNamedLock -SqlitePath $sqlite -DatabasePath $db -Name 'v4-migration' -Owner $owner}catch{}
    Restore-FsOperationalDatabaseMode
}
