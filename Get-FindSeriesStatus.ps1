[CmdletBinding()]
param(
    [string]$Project,
    [int]$ProjectId=0,
    [string]$Workspace,
    [string]$SqlitePath,
    [switch]$Errors,
    [switch]$ResetFailed,
    [switch]$RepairStale
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Review.psm1') -Force -DisableNameChecking

$paths=Get-FsWorkspacePaths -Workspace $Workspace
$db=$paths.Database
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw "FindSeries-Datenbank nicht gefunden: $db"}
$sqlite=Resolve-FsSqlitePath -SqlitePath $SqlitePath -Workspace $paths.Root
[void](Assert-FsSqliteVersion -SqlitePath $sqlite)
Ensure-FsDownloadTuningSchema -SqlitePath $sqlite -DatabasePath $db

if($ProjectId -le 0){
    if([string]::IsNullOrWhiteSpace($Project)){
        $rows=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT id,name,profile,updated_at FROM projects ORDER BY updated_at DESC;'
        $rows|Format-Table -AutoSize
        return
    }
    $row=Get-FsProjectByName -SqlitePath $sqlite -DatabasePath $db -Name $Project
    if($null -eq $row){throw "Project nicht gefunden: $Project"}
    $ProjectId=[int]$row.id
}else{
    $rows=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT * FROM projects WHERE id=$ProjectId;"
    if($rows.Count -eq 0){throw "ProjectId nicht gefunden: $ProjectId"}
    $row=$rows[0]
}

$taskMaxAttempts=4
try{
    if($row.PSObject.Properties['config_json'] -and -not[string]::IsNullOrWhiteSpace([string]$row.config_json)){
        $storedConfig=ConvertTo-FsHashtable ([string]$row.config_json|ConvertFrom-Json)
        $taskMaxAttempts=Get-FsTaskMaxAttempts -Config $storedConfig
    }
}catch{}

if($RepairStale -or $ResetFailed){
    $maintenanceLock=$null
    try{
        $maintenanceLock=Open-FsProjectRunLock -Workspace $paths.Root -ProjectId $ProjectId -ProjectName ([string]$row.name)
        if($RepairStale){
            $stale=Stop-FsStaleRuns -SqlitePath $sqlite -DatabasePath $db -ProjectId $ProjectId -Reason 'Manuell mit Get-FindSeriesStatus.ps1 -RepairStale bereinigt.'
            Reset-FsProjectRunningTasks -ProjectId $ProjectId -SqlitePath $sqlite -DatabasePath $db
            Write-Host ("Veraltete Runs bereinigt: {0}; running-Tasks wurden auf pending gesetzt." -f $stale) -ForegroundColor Green
        }

        if($ResetFailed){
            $now=Get-FsUtcNowText;$nowSql=ConvertTo-FsSqlLiteral $now
            Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
UPDATE project_categories SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='failed';
UPDATE search_tasks SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='failed';
UPDATE metadata_tasks SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='failed';
UPDATE neighbor_tasks SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='failed';
UPDATE project_downloads SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='failed';
UPDATE downloads SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE owner_project_id=$ProjectId AND status='failed';
"@|Out-Null
            Write-Host 'Fehlgeschlagene Aufgaben wurden mit zurückgesetztem Versuchszähler auf pending gesetzt.' -ForegroundColor Green
        }
    }
    finally{Close-FsProjectRunLock -Lock $maintenanceLock}
}

$s=Get-FsProjectSummary -SqlitePath $sqlite -DatabasePath $db -ProjectId $ProjectId
Write-Host "Project: $($row.name) (#$ProjectId), Profil $($row.profile)" -ForegroundColor Cyan
Write-Host ("Medien: {0}; Kategorien: {1}; Datenbank: {2}" -f $s.media_count,$s.category_count,$db) -ForegroundColor Gray
$reviewTables=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT COUNT(*) count FROM sqlite_master WHERE type='table' AND name IN ('review_exports','media_rejections');")
if($reviewTables.Count -gt 0 -and [int]$reviewTables[0].count -eq 2){
    $reviewStats=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM review_exports WHERE project_id=$ProjectId AND status='open') review_open,
 (SELECT COUNT(*) FROM review_exports WHERE project_id=$ProjectId AND status='rejected') review_rejected,
 (SELECT COUNT(*) FROM media_rejections) global_rejection_identities;
"@)
    if($reviewStats.Count -gt 0){
        $reviewRoot=Get-FsReviewProjectRoot -Workspace $paths.Root -ProjectSlug ([string]$row.slug)
        Write-Host ("Review: {0} offen; {1} verworfen; {2} globale Sperridentitäten" -f $reviewStats[0].review_open,$reviewStats[0].review_rejected,$reviewStats[0].global_rejection_identities) -ForegroundColor DarkCyan
        Write-Host ("        {0}" -f $reviewRoot) -ForegroundColor DarkGray
    }
}else{
    Write-Host 'Review: Schema wird beim ersten HF11-Start oder Review-Sync initialisiert.' -ForegroundColor DarkGray
}

$stageRows=foreach($stage in @('category','query','metadata','neighbor','download')){
    $c=Get-FsStageCounts -SqlitePath $sqlite -DatabasePath $db -ProjectId $ProjectId -Stage $stage -MaxAttempts $taskMaxAttempts
    $total=[int]$c.pending+[int]$c.retryable+[int]$c.running+[int]$c.done+[int]$c.failed+[int]$c.skipped+[int]$c.reused
    [pscustomobject]@{
        stage=$stage
        total=$total
        successful=([int]$c.done+[int]$c.reused)
        done=[int]$c.done
        reused=[int]$c.reused
        pending=[int]$c.pending
        retryable=[int]$c.retryable
        running=[int]$c.running
        failed_final=[int]$c.failed
        skipped=[int]$c.skipped
    }
}
$stageRows|Format-Table -AutoSize

try{
    $tune=Get-FsDownloadAutoTuneStatus -ProjectId $ProjectId -SqlitePath $sqlite -DatabasePath $db
    if($null -ne $tune){
        $currentMBps=[double]$tune.WindowBytesPerSecond/1MB
        $downloadRow=@($stageRows | Where-Object {$_.stage -eq 'download'} | Select-Object -First 1)
        $sessionProcessed=0;$sessionDone=0;$sessionReused=0
        if($downloadRow.Count -gt 0 -and [int]$tune.RunId -gt 0){
            $currentTerminal=[int]$downloadRow[0].done+[int]$downloadRow[0].reused+[int]$downloadRow[0].failed_final+[int]$downloadRow[0].skipped
            $sessionProcessed=[Math]::Max(0,$currentTerminal-[int]$tune.RunStartTerminal)
            $sessionDone=[Math]::Max(0,[int]$downloadRow[0].done-[int]$tune.RunStartDone)
            $sessionReused=[Math]::Max(0,[int]$downloadRow[0].reused-[int]$tune.RunStartReused)
        }
        Write-Host ("Anfragesteuerung: {0}" -f $(if($tune.Enabled){'aktiv'}else{'aus'})) -ForegroundColor DarkCyan
        $remainingInWindow=[Math]::Max(0,[int]$tune.WindowTarget-[int]$tune.WindowSuccesses)
        $cooldownRemaining=if([long]$tune.CooldownUntilMs -gt 0){[Math]::Max(0,[int][Math]::Ceiling(([long]$tune.CooldownUntilMs-(Get-FsUnixMilliseconds))/1000.0))}else{0}
        if(-not[bool]$tune.Enabled){
            Write-Host ("          Anfrageabstand {0} ms fest; AutoTune aus; keine automatische Absenkung." -f $tune.CurrentDelayMs) -ForegroundColor DarkCyan
        }elseif($cooldownRemaining -gt 0){
            Write-Host ("          Gemeinsame HTTP-429-Pause noch ca. {0}s; danach 3s gestaffelter Wiederanlauf bei {1} ms." -f $cooldownRemaining,$tune.CurrentDelayMs) -ForegroundColor DarkCyan
        }elseif([bool]$tune.BurstOpen){
            $successesRemaining=[Math]::Max(0,8-[int]$tune.WindowSuccesses)
            $quietRemaining=if([long]$tune.Last429AtMs -gt 0){[Math]::Max(0,[int][Math]::Ceiling(60.0-((Get-FsUnixMilliseconds)-[long]$tune.Last429AtMs)/1000.0))}else{60}
            Write-Host ("          Anfrageabstand {0} ms; Stabilisierung nach 429: noch {1} Erfolge und {2}s ohne neue 429." -f $tune.CurrentDelayMs,$successesRemaining,$quietRemaining) -ForegroundColor DarkCyan
        }elseif([int]$tune.CurrentDelayMs -gt 0){
            $decrease=[Math]::Min(100,[Math]::Max(20,[int][Math]::Ceiling([int]$tune.CurrentDelayMs*0.10)))
            Write-Host ("          Anfrageabstand {0} ms; Messfenster noch {1} erfolgreiche Dateien; danach durchsatzabhängige Halten/Reduzieren-Entscheidung." -f $tune.CurrentDelayMs,$remainingInWindow) -ForegroundColor DarkCyan
        }else{
            Write-Host '          Anfrageabstand 0 ms; keine zusätzliche künstliche Wartezeit.' -ForegroundColor DarkCyan
        }
        Write-Host ("          HTTP 429 seit Laufstart: {0} Antwort(en) in {1} Burst(s)." -f $tune.Total429,$tune.ThrottleBursts) -ForegroundColor DarkCyan
        Write-Host ("          Messung (nur Information): aktuelles Fenster {0}/{1}; {2:N2} Dateien/s; {3:N2} MB/s." -f $tune.WindowSuccesses,$tune.WindowTarget,$tune.WindowFilesPerSecond,$currentMBps) -ForegroundColor DarkGray
        if([bool]$tune.HasCompletedWindow){
            Write-Host ("          Letztes vollständiges Fenster: {0} ms; {1} Dateien; {2:N2} Dateien/s; {3:N2} MB/s." -f $tune.LastWindowDelayMs,$tune.LastWindowSuccesses,$tune.LastWindowFilesPerSecond,([double]$tune.LastWindowBytesPerSecond/1MB)) -ForegroundColor DarkGray
        }
        if($null -ne $tune.BestDelayMs){
            Write-Host ("          Schnellstes gemessenes Fenster (nur Information): {0} ms; {1:N2} Dateien/s; {2:N2} MB/s." -f $tune.BestDelayMs,$tune.BestFilesPerSecond,([double]$tune.BestBytesPerSecond/1MB)) -ForegroundColor DarkGray
        }
        Write-Host ("          Dieser Lauf: {0} bearbeitet ({1} neu heruntergeladen, {2} bereits vorhanden)." -f $sessionProcessed,$sessionDone,$sessionReused) -ForegroundColor DarkCyan
        Write-Host ("          Letzte Regelentscheidung: {0}" -f $tune.LastChangeReason) -ForegroundColor DarkGray
        Write-Host ("          Monitor: .\Show-FindSeriesDownloadMonitor.ps1 -Project `"{0}`" -Workspace `"{1}`"" -f $row.name,$paths.Root) -ForegroundColor DarkGray
    }
}catch{
    Write-Host ("Anfragesteuerungs-Status vorübergehend nicht lesbar: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
}

$runs=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT id,mode,status,started_at,finished_at,error FROM runs WHERE project_id=$ProjectId ORDER BY id DESC LIMIT 10;"
$runs|Format-Table -Wrap -AutoSize
if($Errors){
    $taskErrors=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql @"
SELECT stage,state,attempts,COUNT(*) count,error FROM (
 SELECT 'category' stage,CASE WHEN attempts<$taskMaxAttempts THEN 'retryable' ELSE 'final' END state,attempts,COALESCE(NULLIF(last_error,''),'(ohne Fehlertext)') error FROM project_categories WHERE project_id=$ProjectId AND status='failed'
 UNION ALL SELECT 'query',CASE WHEN attempts<$taskMaxAttempts THEN 'retryable' ELSE 'final' END,attempts,COALESCE(NULLIF(last_error,''),'(ohne Fehlertext)') FROM search_tasks WHERE project_id=$ProjectId AND status='failed'
 UNION ALL SELECT 'metadata',CASE WHEN attempts<$taskMaxAttempts THEN 'retryable' ELSE 'final' END,attempts,COALESCE(NULLIF(last_error,''),'(ohne Fehlertext)') FROM metadata_tasks WHERE project_id=$ProjectId AND status='failed'
 UNION ALL SELECT 'neighbor',CASE WHEN attempts<$taskMaxAttempts THEN 'retryable' ELSE 'final' END,attempts,COALESCE(NULLIF(last_error,''),'(ohne Fehlertext)') FROM neighbor_tasks WHERE project_id=$ProjectId AND status='failed'
 UNION ALL SELECT 'download',CASE WHEN attempts<$taskMaxAttempts THEN 'retryable' ELSE 'final' END,attempts,COALESCE(NULLIF(last_error,''),'(ohne Fehlertext)') FROM project_downloads WHERE project_id=$ProjectId AND status='failed'
) x GROUP BY stage,state,attempts,error ORDER BY state DESC,count DESC LIMIT 40;
"@
    if(@($taskErrors).Count -gt 0){Write-Host 'Task-Fehlergruppen:' -ForegroundColor Yellow;$taskErrors|Format-Table -Wrap -AutoSize}
    $events=Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT created_at,stage,level,message FROM events WHERE project_id=$ProjectId AND level IN ('error','warning') ORDER BY id DESC LIMIT 100;"
    Write-Host 'Ereignisprotokoll:' -ForegroundColor Yellow
    $events|Format-Table -Wrap -AutoSize
}
