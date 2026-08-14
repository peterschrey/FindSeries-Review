# FindSeries V5.0.14 Hotfix 66 - SQLite-based Wikimedia Commons research pipeline
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Alias('Topic')][string]$Project,
    [ValidateSet('Categories','Keywords','Combined','Depicts','Neighbours','Download','Full','Resume','Status')]
    [string]$Mode='Combined',
    [ValidateSet('Fast','Balanced','Deep')][string]$Profile='Balanced',
    [string[]]$Category=@(),
    [Alias('SearchTerm')][string[]]$Keyword=@(),
    [Alias('KeywordSet')][string[]]$KeywordGroup=@(),
    [ValidatePattern('^Q\d+$')][string[]]$Depicts=@(),
    [string]$Language='de',
    [string]$Domain='Dentistry',
    [string]$Config,
    [string[]]$Set=@(),
    [ValidateRange(0,16)][int]$Workers=0,
    [switch]$ListOnly,
    [string]$Workspace,
    [string]$SqlitePath,
    [switch]$NoMonitor
)
$ErrorActionPreference='Stop'
try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}catch{}

$script:StartupStopwatch=[Diagnostics.Stopwatch]::StartNew()
$script:StartupTotalSteps=8
$script:StartupStepStarted=$null

function Format-StartupDuration {
    param([double]$Seconds)
    if($Seconds -lt 0){return '--:--'}
    $span=[TimeSpan]::FromSeconds($Seconds)
    if($span.TotalDays -ge 1){return $span.ToString('d\.hh\:mm\:ss')}
    if($span.TotalHours -ge 1){return $span.ToString('hh\:mm\:ss')}
    return $span.ToString('mm\:ss')
}

function Start-StartupStep {
    param([int]$Step,[string]$Title,[string]$Detail)
    $script:StartupStepStarted=[Diagnostics.Stopwatch]::StartNew()
    $elapsed=Format-StartupDuration $script:StartupStopwatch.Elapsed.TotalSeconds
    Write-Host ''
    Write-Host ("[START {0}/{1}] {2} | Gesamtlaufzeit {3}" -f $Step,$script:StartupTotalSteps,$Title,$elapsed) -ForegroundColor Cyan
    if(-not[string]::IsNullOrWhiteSpace($Detail)){Write-Host ("              {0}" -f $Detail) -ForegroundColor DarkGray}
}

function Complete-StartupStep {
    param([int]$Step,[string]$Title,[string]$Detail)
    $stepSeconds=if($null -ne $script:StartupStepStarted){$script:StartupStepStarted.Elapsed.TotalSeconds}else{0}
    $elapsed=Format-StartupDuration $script:StartupStopwatch.Elapsed.TotalSeconds
    $stepTime=Format-StartupDuration $stepSeconds
    Write-Host ("[FERTIG {0}/{1}] {2} | Schritt {3} | gesamt {4}" -f $Step,$script:StartupTotalSteps,$Title,$stepTime,$elapsed) -ForegroundColor Green
    if(-not[string]::IsNullOrWhiteSpace($Detail)){Write-Host ("               {0}" -f $Detail) -ForegroundColor DarkGray}
}


function Stop-FsExistingDownloadMonitors {
    try{
        $oldMonitors=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{
            $_.ProcessId -ne $PID -and
            $_.Name -match '^(powershell|pwsh)\.exe$' -and
            -not[string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
            [string]$_.CommandLine -match 'Show-FindSeriesDownloadMonitor(?:-HF[0-9A-Za-z]+)?\.ps1'
        })
        foreach($oldMonitor in $oldMonitors){
            Write-Host ("        [MONITOR] alte Monitorinstanz PID {0} wird beendet." -f $oldMonitor.ProcessId) -ForegroundColor DarkGray
            Stop-Process -Id $oldMonitor.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if($oldMonitors.Count -gt 0){Start-Sleep -Milliseconds 750}
        return $oldMonitors.Count
    }catch{
        Write-Host ("        [MONITOR] alte Instanzen konnten nicht vollständig geprüft werden: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        return 0
    }
}

function Start-FsAutomaticDownloadMonitor {
    param([string]$ProjectName,[string]$WorkspacePath)
    $monitorPath=Join-Path $PSScriptRoot 'Show-FindSeriesDownloadMonitor.ps1'
    if(-not(Test-Path -LiteralPath $monitorPath -PathType Leaf)){
        Write-Host '        [MONITOR] Monitor-Skript fehlt; Download läuft ohne separate Ansicht.' -ForegroundColor DarkYellow
        return $false
    }

    # Stop a monitor that may have been started manually after application
    # startup, then launch the one belonging to this run.
    [void](Stop-FsExistingDownloadMonitors)

    $diagnostics=Join-Path $WorkspacePath 'Diagnostics'
    if(-not(Test-Path -LiteralPath $diagnostics)){
        New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
    }
    $projectSlug=[regex]::Replace($ProjectName,'[^A-Za-z0-9._-]+','_')
    $readyFile=Join-Path $diagnostics ("download-monitor-{0}.ready" -f $projectSlug)
    $monitorLog=Join-Path $diagnostics 'download-monitor.log'
    Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue

    # Use Windows PowerShell explicitly: WinForms is always available there and
    # STA is deterministic. Do not start the process with SW_HIDE; that may hide
    # its first WinForms top-level window as well. The monitor hides only its own
    # console after the form is visible.
    $windowsPowerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shellPath=if(Test-Path -LiteralPath $windowsPowerShell -PathType Leaf){$windowsPowerShell}else{'powershell.exe'}
    $monitorArgs=@(
        '-NoLogo','-NoProfile','-Sta','-ExecutionPolicy','Bypass',
        '-File',('"'+$monitorPath+'"'),
        '-Project',('"'+$ProjectName+'"'),
        '-Workspace',('"'+$WorkspacePath+'"'),
        '-Mode','Gui',
        '-ReadyFile',('"'+$readyFile+'"'),
        '-HideConsole'
    )
    try{
        $monitorProcess=Start-Process -FilePath $shellPath -ArgumentList $monitorArgs -WorkingDirectory $PSScriptRoot -PassThru
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        while([DateTime]::UtcNow -lt $deadline){
            if(Test-Path -LiteralPath $readyFile -PathType Leaf){
                Write-Host ("        [MONITOR] Live-Ansicht sichtbar gestartet (PID {0})." -f $monitorProcess.Id) -ForegroundColor Cyan
                return $true
            }
            if($monitorProcess.HasExited){
                $detail=''
                if(Test-Path -LiteralPath $monitorLog -PathType Leaf){
                    try{$detail=((Get-Content -LiteralPath $monitorLog -Tail 8 -ErrorAction Stop) -join ' ')}catch{}
                }
                if([string]::IsNullOrWhiteSpace($detail)){$detail=("Prozess endete mit ExitCode {0}." -f $monitorProcess.ExitCode)}
                Write-Host ("        [MONITOR] Start fehlgeschlagen: {0}" -f $detail) -ForegroundColor DarkYellow
                return $false
            }
            Start-Sleep -Milliseconds 250
        }
        Write-Host ("        [MONITOR] Prozess PID {0} läuft, hat die sichtbare GUI aber nicht innerhalb von 20 s bestätigt. Details: {1}" -f $monitorProcess.Id,$monitorLog) -ForegroundColor DarkYellow
        return $false
    }
    catch{
        Write-Host ("        [MONITOR] automatischer Start fehlgeschlagen; Download läuft weiter: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        return $false
    }
}

Start-StartupStep 1 'PowerShell-Module laden' 'Configuration, Database, Core, API, Search und Review werden geladen.'
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $PSScriptRoot
if(-not $NoMonitor){[void](Stop-FsExistingDownloadMonitors)}
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Api.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Review.psm1') -Force -DisableNameChecking
Complete-StartupStep 1 'PowerShell-Module geladen' $null

$runLock=$null
$runId=0
$projectId=0
$projectRow=$null
$runLock=Open-FsProjectRunLock -Workspace $Workspace -ProjectId 0 -ProjectName $Project

try {
Start-StartupStep 2 'Workspace und Datenbank initialisieren' 'Schema, WAL und Medienidentitäten werden geprüft. Bei vielen offenen Dubletten folgen Restdauer und voraussichtliche Abschlusszeit.'
$init=Initialize-FsDatabase -Workspace $Workspace -SqlitePath $SqlitePath -ShowProgress
$paths=$init.Paths;$sqlite=$init.SqlitePath;$db=$paths.Database
Complete-StartupStep 2 'Workspace und Datenbank bereit' $db

Start-StartupStep 3 'Profil und Parameter auswerten' "Profil '$Profile', $($Set.Count) CLI-Override(s)."
$profilesPath=Join-Path $PSScriptRoot 'Config\profiles.json'
$configObject=Get-FsProjectConfig -Profile $Profile -ProfilesPath $profilesPath -ConfigPath $Config -Override $Set
$userAgent=Get-FsHttpUserAgent -Config $configObject -Version '5.0.14-hotfix66'
$headers=Get-FsHttpHeaders -Config $configObject -Version '5.0.14-hotfix66'
$configJson=$configObject|ConvertTo-Json -Depth 20 -Compress
Complete-StartupStep 3 'Profil und Parameter ausgewertet' ("API-Delay {0} ms; max. Suchabfragen {1}" -f $configObject.Api.DelayMs,$configObject.Keyword.MaxQueries)

function Show-Header {
    Write-Host ''
    Write-Host ('='*86) -ForegroundColor DarkCyan
    Write-Host '  FindSeries V5.0.14 Hotfix 66 - SQLite Research Pipeline' -ForegroundColor Cyan
    Write-Host ('='*86) -ForegroundColor DarkCyan
    Write-Host ("  Project       : $Project") -ForegroundColor White
    Write-Host ("  Modus / Profil: $Mode / $Profile") -ForegroundColor Gray
    Write-Host ("  Workspace     : $($paths.Root)") -ForegroundColor Gray
    Write-Host ("  Datenbank     : $db (WAL)") -ForegroundColor Gray
    Write-Host ("  Kategorien    : $(if($Category.Count){$Category -join ', '}else{'keine'})") -ForegroundColor Gray
    Write-Host ("  Keywords      : $(if($Keyword.Count){$Keyword -join ', '}else{'keine'})") -ForegroundColor Gray
    Write-Host ("  Keyword-Gruppen: $(if($KeywordGroup.Count){$KeywordGroup -join ' | '}else{'keine'})") -ForegroundColor Gray
    Write-Host ("  API-Gate      : $($configObject.Api.DelayMs) ms Basisabstand; 429/Retry-After kann temporär erhöhen") -ForegroundColor DarkGray
    $effectiveDownloadDelay=[Math]::Max(0,[int]$configObject.Download.DelayMs)
    $effectiveDownloadWorkers=Get-FsWorkerCount -Config $configObject -Stage 'download' -OverrideWorkers $Workers
    Write-Host ("  User-Agent    : $userAgent") -ForegroundColor DarkGray
    $autoTuneEnabled=($configObject.Download.ContainsKey('AutoTune') -and [bool]$configObject.Download.AutoTune)
    Write-Host ("  Download-Gate : {0} ms sicherer Startwert; Anfragesteuerung {1}; bei 429 gemeinsame Pause und einmalige gestaffelte Wiederanlaufwelle; {2} Retry(s); Timeout {3}s" -f $effectiveDownloadDelay,$(if($autoTuneEnabled){'aktiv'}else{'aus'}),$configObject.Download.Retries,$configObject.Download.TimeoutSeconds) -ForegroundColor DarkGray
    $effectiveClaimBatch=if($configObject.Download.ContainsKey('ClaimBatchSize')){[Math]::Max(1,[int]$configObject.Download.ClaimBatchSize)}else{4}
    $effectiveCompletionBatch=if($configObject.Download.ContainsKey('CompletionBatchSize')){[Math]::Max(1,[int]$configObject.Download.CompletionBatchSize)}else{4}
    Write-Host ("  Download-Worker: $effectiveDownloadWorkers; Claim-Batch $effectiveClaimBatch; Ergebnis-Batch $effectiveCompletionBatch Task(s) je SQLite-Write-Lock") -ForegroundColor DarkGray
    Write-Host ("  Worker        : CLI-Override $(if($Workers){$Workers}else{'Profilwerte'}); Neustart bei Ausfall") -ForegroundColor DarkGray
    Write-Host ('='*86) -ForegroundColor DarkCyan
}

function Show-Summary {
    $s=Get-FsProjectSummary -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId
    Write-Host ''
    Write-Host ("Project '$Project': $($s.media_count) Medien, $($s.category_count) Kategorien") -ForegroundColor Cyan
    foreach($summaryStage in @('category','query','metadata','neighbor','download')){
        $summaryMaxAttempts=if($configObject.ContainsKey('Task') -and $configObject.Task.ContainsKey('MaxAttempts')){[Math]::Max(1,[int]$configObject.Task.MaxAttempts)}else{4}
        $c=Get-FsStageCounts -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Stage $summaryStage -MaxAttempts $summaryMaxAttempts
        $total=[int]$c.pending+[int]$c.retryable+[int]$c.running+[int]$c.done+[int]$c.failed+[int]$c.skipped+[int]$c.reused
        $successful=[int]$c.done+[int]$c.reused
        Write-Host ("  {0,-9}: total {1}; erfolgreich {2}; done {3}; reused {4}; skipped {5}; retryfähig {6}; final failed {7}; pending {8}; running {9}" -f $summaryStage,$total,$successful,$c.done,$c.reused,$c.skipped,$c.retryable,$c.failed,$c.pending,$c.running) -ForegroundColor Gray
    }
    Write-Host ("Status: .\Get-FindSeriesStatus.ps1 -Project `"$Project`"") -ForegroundColor DarkGray
}

    Start-StartupStep 4 'Projekt und Lauf registrieren' 'Der exklusive Projekt-Lock ist aktiv; veraltete Runs und Tasks werden bereinigt.'
    $slug=ConvertTo-FsSlug $Project
    $existingProject=Get-FsProjectByName -SqlitePath $sqlite -DatabasePath $db -Name $Project
    if($null -ne $existingProject){
        $projectId=[int]$existingProject.id
        $projectRow=Save-FsProject -SqlitePath $sqlite -DatabasePath $db -Name $Project -Slug ([string]$existingProject.slug) -Profile $Profile -Language $Language -ConfigJson $configJson
    }else{
        $projectRow=Save-FsProject -SqlitePath $sqlite -DatabasePath $db -Name $Project -Slug $slug -Profile $Profile -Language $Language -ConfigJson $configJson
        $projectId=[int]$projectRow.id
    }
    $projectId=[int]$projectRow.id
    $projectPath=Join-Path $paths.Projects ([string]$projectRow.slug)
    if(-not(Test-Path -LiteralPath $projectPath)){New-Item -ItemType Directory -Path $projectPath -Force|Out-Null}

    $staleRuns=Stop-FsStaleRuns -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId
    Reset-FsProjectRunningTasks -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db

    # Hotfix-3-Migration: ausschließlich den bekannten, technisch erzeugten
    # Empty-Statements-Fehler zurücksetzen. Andere endgültige Fehler bleiben unberührt.
    $legacyStatementsPattern='Das Argument kann nicht an den Parameter "Statements" gebunden werden%'
    $recoveredLegacyStatementTasks=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql @"
UPDATE project_categories
SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$(ConvertTo-FsSqlLiteral (Get-FsUtcNowText))
WHERE project_id=$projectId AND status='failed' AND last_error LIKE $(ConvertTo-FsSqlLiteral $legacyStatementsPattern)
RETURNING category_id;
"@)
    if($recoveredLegacyStatementTasks.Count -gt 0){Write-Host ("        [REPARATUR] {0} Kategorie-Task(s) mit altem Empty-Statements-Fehler erneut eingereiht." -f $recoveredLegacyStatementTasks.Count) -ForegroundColor DarkYellow}

    $parameters=[ordered]@{Project=$Project;Mode=$Mode;Profile=$Profile;Category=$Category;Keyword=$Keyword;KeywordGroup=$KeywordGroup;Depicts=$Depicts;Language=$Language;Domain=$Domain;ListOnly=[bool]$ListOnly;Set=$Set;Hotfix='5.0.14-hotfix66'}
    $runId=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode $Mode -Profile $Profile -ParametersJson ($parameters|ConvertTo-Json -Depth 10 -Compress)
    $profilePath=Initialize-FsDiagnostics -Config $configObject -Workspace $paths.Root -ProjectId $projectId -RunId $runId -Worker 'orchestrator' -Stage 'orchestrator'
    $workerPath=Join-Path $PSScriptRoot 'FindSeries.Worker.ps1'
    Complete-StartupStep 4 'Projekt und Lauf registriert' ("Project-ID {0}; Run-ID {1}; bereinigte alte Runs {2}" -f $projectId,$runId,$staleRuns)

    Show-Header
    if([int]$configObject.Keyword.Workers -gt 1){Write-Warning "Keyword.Workers=$($configObject.Keyword.Workers) erzeugt parallele 500er-Schreibbatches. Für stabile Resume-Läufe wird zunächst Keyword.Workers=1 empfohlen."}
    if(Test-FsDiagnosticsEnabled){Write-Host ("  Profiling     : aktiv -> {0}" -f $profilePath) -ForegroundColor Magenta;Write-Host ("  Auswertung    : .\Get-FindSeriesPerformance.ps1 -RunId {0}" -f $runId) -ForegroundColor DarkGray}

    # Review-Sync happens before any queue is seeded or claimed. Deletions from
    # Explorer therefore become global exclusions before another keyword,
    # category, neighbor or download stage can encounter the image again.
    $reviewBefore=Sync-FsReview -ProjectId $projectId -Workspace $paths.Root -Config $configObject -SqlitePath $sqlite -DatabasePath $db

    Start-StartupStep 5 'Worker-Leases prüfen' 'Abgelaufene running-Tasks werden wieder auf pending gesetzt; die Prüfung wird während jeder Stufe wiederholt.'
    Reset-FsExpiredTasks -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db
    $prunedCategoryTasks=0
    if($Mode -in @('Categories','Combined','Full','Resume')){
        $prunedCategoryTasks=Invoke-FsCategoryQueuePrune -ProjectId $projectId -CategoryConfig $configObject.Category -SqlitePath $sqlite -DatabasePath $db
        if($prunedCategoryTasks -gt 0){Write-Host ("        [CATEGORY-PRUNE] {0} bereits eingereihte Drift-Kategorie(n) übersprungen." -f $prunedCategoryTasks) -ForegroundColor DarkYellow}
    }
    Complete-StartupStep 5 'Worker-Leases geprüft' $(if($prunedCategoryTasks -gt 0){"DriftGuard: $prunedCategoryTasks Kategorie(n) bereinigt."}else{$null})

    if($Mode -eq 'Status'){
        Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $runId
        Show-Summary
        return
    }

    Start-StartupStep 6 'Kategorien vorbereiten' ("{0} explizite Startkategorie(n)." -f $Category.Count)
    if($Mode -ne 'Resume' -and $Mode -in @('Categories','Combined','Full') -and $Category.Count -gt 0){Seed-FsCategoryTasks -ProjectId $projectId -Categories $Category -SqlitePath $sqlite -DatabasePath $db}
    Complete-StartupStep 6 'Kategorien vorbereitet' $null

    Start-StartupStep 7 'Suchbegriffe, Übersetzungen und Suchaufgaben vorbereiten' ("{0} Keyword(s), {1} Gruppe(n), {2} Depicts-QID(s). Restdauer und voraussichtliche Abschlusszeit werden nach den ersten Sprachen berechnet." -f $Keyword.Count,$KeywordGroup.Count,$Depicts.Count)
    if($Mode -ne 'Resume' -and $Mode -in @('Keywords','Combined','Depicts','Full') -and ($Keyword.Count -gt 0 -or $KeywordGroup.Count -gt 0 -or $Depicts.Count -gt 0)){
        $lockOwner="translations-$PID-$runId"
        Write-Host '        [LOCK] Übersetzungs-Lock anfordern; maximale Wartezeit 15 Minuten ...' -ForegroundColor DarkGray
        $lockWatch=[Diagnostics.Stopwatch]::StartNew()
        if(-not(Acquire-FsNamedLock -SqlitePath $sqlite -DatabasePath $db -Name 'translations' -Owner $lockOwner -LeaseSeconds 900 -WaitSeconds 900)){throw 'Übersetzungs-Lock konnte nicht erworben werden.'}
        Write-Host ("        [LOCK] erhalten nach {0}" -f (Format-StartupDuration $lockWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
        try{
            $count=Seed-FsSearchTasks -ProjectId $projectId -Keywords $Keyword -KeywordGroups $KeywordGroup -Depicts $Depicts -Language $Language -Domain $Domain -Config $configObject -SqlitePath $sqlite -DatabasePath $db -Headers $headers -RunId $runId -ShowProgress
            Write-Host ("        [SEED] $count Suchabfragen vorbereitet") -ForegroundColor DarkGray
        }finally{Release-FsNamedLock -SqlitePath $sqlite -DatabasePath $db -Name 'translations' -Owner $lockOwner}
    }
    Complete-StartupStep 7 'Suchaufgaben vorbereitet' $null

    Start-StartupStep 8 'Pipeline-Stufen planen' 'Offene Tasks werden gezählt und die benötigten Worker gestartet.'
    $stages=Get-FsModeStages -Mode $Mode -ListOnly:$ListOnly
    $capacityRows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT (SELECT COUNT(*) FROM project_categories WHERE project_id=$projectId) category_count,(SELECT COUNT(*) FROM project_media WHERE project_id=$projectId) media_count;")
    $existingCategories=if($capacityRows.Count){[int]$capacityRows[0].category_count}else{0};$existingMedia=if($capacityRows.Count){[int]$capacityRows[0].media_count}else{0}
    $categoryLimit=[int]$configObject.Category.MaxCategories;$mediaLimit=[int]$configObject.Category.MaxFiles
    Write-Host ("        [KAPAZITÄT] Bestand: {0} Kategorien / {1} Medien; Limits: {2} / {3}" -f $existingCategories,$existingMedia,$categoryLimit,$mediaLimit) -ForegroundColor DarkGray
    $capacityProblems=New-Object Collections.Generic.List[string]
    $categoryAtLimit=($existingCategories -ge $categoryLimit)
    $mediaAtLimit=($existingMedia -ge $mediaLimit)

    # HF66-RESUME-CAPACITY: Capacity limits constrain discovery. They must not
    # prevent Resume from processing metadata/downloads for media already in the
    # project. Older versions aborted the complete pipeline when the historical
    # project count already met/exceeded a configured discovery limit.
    if($Mode -eq 'Resume'){
        if($categoryAtLimit -and $stages -contains 'category'){
            Write-Warning ("Kategorielimit erreicht: Bestand {0}, Limit {1}. Resume: Discovery-Stufe 'category' wird übersprungen; nachgelagerte Stufen laufen weiter." -f $existingCategories,$categoryLimit)
            $stages=@($stages | Where-Object {$_ -ne 'category'})
        }
        if($mediaAtLimit -and ($stages -contains 'category' -or $stages -contains 'query')){
            Write-Warning ("Medienlimit erreicht: Bestand {0}, Limit {1}. Resume: Discovery-Stufen 'category'/'query' werden übersprungen; nachgelagerte Stufen laufen weiter." -f $existingMedia,$mediaLimit)
            $stages=@($stages | Where-Object {$_ -notin @('category','query')})
        }
    }else{
        if($categoryAtLimit -and $stages -contains 'category'){$capacityProblems.Add(("Kategorielimit erreicht: Bestand {0}, Limit {1}. Ergänze z. B. `"Category.MaxCategories={2}`"." -f $existingCategories,$categoryLimit,[Math]::Max(10000,$existingCategories+1000)))}
        if($mediaAtLimit -and ($stages -contains 'category' -or $stages -contains 'query')){$capacityProblems.Add(("Medienlimit erreicht: Bestand {0}, Limit {1}. Ergänze z. B. `"Category.MaxFiles={2}`"." -f $existingMedia,$mediaLimit,[Math]::Max(500000,$existingMedia+100000)))}
        if($capacityProblems.Count -gt 0){foreach($problem in $capacityProblems){Write-Warning $problem};throw ("Pipeline vor dem Worker-Start abgebrochen, weil konfigurierte Kapazitätsgrenzen bereits erreicht sind. "+($capacityProblems -join ' '))}
    }

    $reactivateNow=Get-FsUtcNowText
    $reactivateCategorySql=''
    $reactivateQuerySql=''
    if(($stages -contains 'category') -and -not $categoryAtLimit -and -not $mediaAtLimit){
        $reactivateCategorySql="UPDATE project_categories SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$(ConvertTo-FsSqlLiteral $reactivateNow) WHERE project_id=$projectId AND status='skipped' AND last_error IN ('Kategorielimit erreicht','Dateilimit erreicht');"
    }
    if(($stages -contains 'query') -and -not $mediaAtLimit){
        $reactivateQuerySql="UPDATE search_tasks SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$(ConvertTo-FsSqlLiteral $reactivateNow) WHERE project_id=$projectId AND status='skipped' AND last_error='Dateilimit erreicht';"
    }
    if((-not [string]::IsNullOrWhiteSpace($reactivateCategorySql)) -or (-not [string]::IsNullOrWhiteSpace($reactivateQuerySql))){
        Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql ("BEGIN IMMEDIATE;`n{0}`n{1}`nCOMMIT;" -f $reactivateCategorySql,$reactivateQuerySql)|Out-Null
    }

    Complete-StartupStep 8 'Startvorbereitung abgeschlossen' ("Pipeline startet nach {0}; Stufen: {1}" -f (Format-StartupDuration $script:StartupStopwatch.Elapsed.TotalSeconds),($stages -join ', '))

    $monitorStarted=$false
    $taskMaxAttempts=if($configObject.ContainsKey('Task') -and $configObject.Task.ContainsKey('MaxAttempts')){[Math]::Max(1,[int]$configObject.Task.MaxAttempts)}else{4}

    for($stageIndex=0;$stageIndex -lt $stages.Count;$stageIndex++){
        $stage=$stages[$stageIndex]
        switch($stage){
            'metadata'{
                $metadataSeedBatchSize=if($configObject.Metadata.ContainsKey('SeedBatchSize')){[int]$configObject.Metadata.SeedBatchSize}else{2000}
                $metadataSeed=Seed-FsMetadataTasks -ProjectId $projectId -Level ([int]$configObject.Metadata.Level) -SqlitePath $sqlite -DatabasePath $db -SeedBatchSize $metadataSeedBatchSize
                if([bool]$metadataSeed.FastPath){
                    Write-Host ("        [META-SEED] Level {0}: Fast-Path; {1} Projektmedien final, {2} offen; kein Bestandsscan." -f $metadataSeed.Level,$metadataSeed.Media,$metadataSeed.Open) -ForegroundColor DarkGray
                }else{
                    Write-Host ("        [META-SEED] Level {0}: nur Abdeckungsdelta geprüft ({1} von {2} Projektmedien); {3} neue Kandidaten; {4} Tasks offen; {5} Tasks neu/reaktiviert; Seeding {6:N1}s." -f $metadataSeed.Level,$metadataSeed.Scanned,$metadataSeed.Media,$metadataSeed.Candidates,$metadataSeed.Open,$metadataSeed.Changed,$metadataSeed.SeedSeconds) -ForegroundColor DarkGray
                }
            }
            'neighbor'{if($Mode -eq 'Neighbours' -or [bool]$configObject.Neighbors.Enabled){Seed-FsNeighborTasks -ProjectId $projectId -Config $configObject -SqlitePath $sqlite -DatabasePath $db}else{Write-Host '        [SKIP] Nachbarsuche ist im Profil deaktiviert.' -ForegroundColor DarkYellow;continue}}
            'download'{
                # Capture the session baseline before seeding so objects reused or
                # finalized during DOWNLOAD-SEED are included in the session total.
                $tuneState=Initialize-FsDownloadAutoTune -ProjectId $projectId -RunId $runId -Config $configObject -SqlitePath $sqlite -DatabasePath $db
                Seed-FsDownloadTasks -ProjectId $projectId -Config $configObject -SqlitePath $sqlite -DatabasePath $db
                if($null -ne $tuneState -and [bool]$tuneState.Enabled){
                    $autoTuneFloor=Get-FsDownloadAutoTuneMinDelayMs -Config $configObject
                    $autoTuneGain=Get-FsDownloadAutoTuneMinImprovementPct -Config $configObject
                    Write-Host ("        [ANFRAGESTEUERUNG] aktiv: Start {0} ms; Floor {1} ms; nach dem Basisfenster wird nur weiter verkürzt, wenn der Dateidurchsatz um mindestens {2:N1} % steigt; bei 429 gemeinsame Pause und moderater Gegen-Schritt." -f $tuneState.CurrentDelayMs,$autoTuneFloor,$autoTuneGain) -ForegroundColor DarkCyan
                    Write-Host ("        [MONITOR] separate Ansicht: .\Show-FindSeriesDownloadMonitor.ps1 -Project `"{0}`" -Workspace `"{1}`"" -f $Project,$paths.Root) -ForegroundColor DarkGray
                }else{
                    Write-Host ("        [ANFRAGESTEUERUNG] deaktiviert; Download.DelayMs={0} wird unverändert verwendet." -f $configObject.Download.DelayMs) -ForegroundColor DarkGray
                }
            }
        }
        $counts=Get-FsStageCounts -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Stage $stage -MaxAttempts $taskMaxAttempts
        if(([int]$counts.pending+[int]$counts.retryable+[int]$counts.running) -eq 0){Write-Host ("        [SKIP] ${stage}: keine offenen Aufgaben") -ForegroundColor DarkYellow;continue}
        if($stage -eq 'download' -and -not $NoMonitor -and -not $monitorStarted){
            # Start only after seed checks and only when download work exists.
            $monitorStarted=Start-FsAutomaticDownloadMonitor -ProjectName $Project -WorkspacePath $paths.Root
        }
        $workerCount=Get-FsWorkerCount -Config $configObject -Stage $stage -OverrideWorkers $Workers
        Write-Host '';Write-Host ("[$($stageIndex+1)/$($stages.Count)] $stage mit $workerCount Worker(n)") -ForegroundColor Cyan
        $textProgressSeconds=if($configObject.Progress.ContainsKey('TextSeconds')){[int]$configObject.Progress.TextSeconds}else{10}
        $stallWarningSeconds=if($configObject.Progress.ContainsKey('StallWarningSeconds')){[int]$configObject.Progress.StallWarningSeconds}else{60}
        Start-FsStageWorkers -WorkerPath $workerPath -Stage $stage -ProjectId $projectId -RunId $runId -Workspace $paths.Root -SqlitePath $sqlite -Config $configObject -Workers $workerCount -PollSeconds ([int]$configObject.Progress.PollSeconds) -TextProgressSeconds $textProgressSeconds -StallWarningSeconds $stallWarningSeconds|Out-Null
    }
    if($stages -contains 'download'){
        # Export files downloaded during this run immediately into the
        # Explorer-friendly review batches.
        $reviewAfter=Sync-FsReview -ProjectId $projectId -Workspace $paths.Root -Config $configObject -SqlitePath $sqlite -DatabasePath $db
    }
    Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $runId -Status 'completed'
    Show-Summary
}
catch{
    if($runId -gt 0){try{Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $runId -Status 'failed' -Error $_.Exception.Message}catch{}}
    if($projectId -gt 0){try{Write-FsEvent -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -RunId $(if($runId -gt 0){$runId}else{$null}) -Stage 'orchestrator' -Level 'error' -Message $_.Exception.Message -Details @{stack=$_.ScriptStackTrace}}catch{}}
    throw
}
finally{
    Close-FsProjectRunLock -Lock $runLock
}
