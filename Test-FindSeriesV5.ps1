# Offline smoke test for database schema, task claims, locks and multi-key media identities.
[CmdletBinding()]
param(
    [string]$Workspace=(Join-Path $env:TEMP ('FindSeriesV5-Test-'+[Guid]::NewGuid().ToString('N'))),
    [string]$SqlitePath,
    [switch]$Keep
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Api.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Review.psm1') -Force -DisableNameChecking



# Hotfix 60: Every Wikimedia request identifies FindSeries and its operator.
# Worker counts and configured baseline delays must pass through unchanged.
$uaConfig=@{Api=@{Contact='mailto:pschrey@gmail.com';DelayMs=137};Download=@{Workers=4;DelayMs=251}}
$selftestVersion='5.0.14-hotfix66'
$selftestUserAgent=Get-FsHttpUserAgent -Config $uaConfig -Version $selftestVersion
if(-not $selftestUserAgent.StartsWith("FindSeriesBot/$selftestVersion ") -or $selftestUserAgent -notmatch 'pschrey@gmail\.com'){
    throw "Wikimedia-User-Agent enthält Botkennung oder Kontakt nicht korrekt: $selftestUserAgent"
}
$selftestHeaders=Get-FsHttpHeaders -Config $uaConfig -Version $selftestVersion
if([string]$selftestHeaders['User-Agent'] -ne $selftestUserAgent){
    throw 'HTTP-Header verwenden nicht den zentral erzeugten Wikimedia-User-Agent.'
}
if((Get-FsWorkerCount -Config $uaConfig -Stage 'download' -OverrideWorkers 0) -ne 4){
    throw 'Download.Workers wird nicht unverändert aus der Konfiguration übernommen.'
}
$mainSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FindSeries.ps1'))
$workerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FindSeries.Worker.ps1'))
$databaseSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1'))
$apiSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Modules\FindSeries.Api.psm1'))
$searchSource28=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1'))


# HF62 regressions: large downloads must not write a lease heartbeat every
# minute; worker-side SHA1 reuse must use downloads.verified_sha1; explicit
# media/download SHA1 mismatches are repaired before the worker queue; and
# neighbor bulk writes start small and can halve down to one row.
if($mainSource -notmatch '5\.0\.14-hotfix66' -or $workerSource -notmatch '5\.0\.14-hotfix66'){
    throw 'HF66-Version ist in Orchestrator oder Worker nicht konsistent.'
}
if($mainSource -notmatch 'HF66-RESUME-CAPACITY' -or
   $mainSource -notmatch 'nachgelagerte Stufen laufen weiter'){
    throw 'HF66 Resume-Kapazitätsbehandlung fehlt.'
}
if($searchSource28 -notmatch 'function Repair-FsInvalidDownloadIdentityRows' -or
   $searchSource28 -notmatch 'lower\(m\.sha1\)<>lower\(d\.verified_sha1\)' -or
   $searchSource28 -notmatch '\$downloadHeartbeatSeconds=\[Math\]::Max\(900,\[int\]\[Math\]::Floor\(\$leaseSeconds/2\.0\)\)' -or
   $searchSource28 -notmatch 'downloads d INDEXED BY ix_downloads_verified_sha1 WHERE d\.verified_sha1 IS NOT NULL' -or
   $searchSource28 -notmatch '\[ValidateRange\(1,250\)\]\[int\]\$ChunkSize=10' -or
   $searchSource28 -notmatch '-Heartbeat \$heartbeat -ChunkSize 10' -or
   $searchSource28 -notmatch '\$effectiveChunk=\[Math\]::Max\(1,'){
    throw 'HF62 Download-Identitätsreparatur, seltene Download-Heartbeats oder kleine Neighbor-Schreibchunks fehlen.'
}
if($databaseSource -notmatch 'ix_downloads_owner_worker_lease' -or
   $databaseSource -notmatch 'ix_project_downloads_worker_lease' -or
   $databaseSource -notmatch 'schema_migrations\(version,applied_at\) VALUES\(62'){
    throw 'HF62 Lease-Indizes oder Schema-Migration 62 fehlen.'
}
$monitorSource62=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Show-FindSeriesDownloadMonitor.ps1'))
if($monitorSource62 -notmatch '\[HF66\]' -or
   $monitorSource62 -notmatch 'Downloads MB/s über die Zeit' -or
   $monitorSource62 -notmatch 'Netzwerkdurchsatz über die Zeit' -or
   $monitorSource62 -notmatch 'MB/s vs\. Aufgaben/s' -or
   $monitorSource62 -notmatch 'MB/s vs\. neue Downloads/s' -or
   $monitorSource62 -notmatch 'Add_FormClosing' -or
   $monitorSource62 -notmatch 'PipelineStoppedException'){
    throw 'HF66 integriert nicht den korrigierten Monitor mit neun Charts und sauberem Schließen.'
}

# HF60: With schema migration V2 present, startup must process only the
# persisted conflict queue. A full media-to-identity scan at every Resume, and
# especially after every merge, caused repeated 180-second SQLite timeouts.
if($databaseSource -notmatch '\[switch\]\$QueueOnly' -or
   $databaseSource -notmatch 'Repair-FsMediaIdentityConflicts.+-QueueOnly.+Medienidentitäten beim Start prüfen' -or
   $databaseSource -notmatch 'Konfliktqueue direkt verarbeiten; kein vollständiger Identitätsabgleich' -or
   $databaseSource -notmatch '\[int\]\$BatchSize\s*=\s*5000' -or
   $databaseSource -notmatch 'id>\$lowerExclusive AND id<=\$upperInclusive' -or
   $databaseSource -match '\$merged\+\+\s*[\r\n]+\s*Sync-FsMediaIdentities'){
    throw 'HF60-Queue-Reparatur überspringt den redundanten Identitäts-Vollscan nicht zuverlässig.'
}
if($mainSource -notmatch 'Get-FsHttpHeaders' -or $workerSource -notmatch 'Get-FsHttpHeaders' -or
   $mainSource -match "FindSeries/5\.0\.14-hotfix53" -or $workerSource -match "FindSeries/5\.0\.14-hotfix53"){
    throw 'Orchestrator oder Worker verwendet nicht den zentralen HF60-User-Agent.'
}
if($databaseSource -match '\[Math\]::Max\(1000,\$DelayMs\)' -or
   $apiSource -match '\[Math\]::Max\(1000,\$DelayMs\)' -or
   $searchSource28 -match '\[Math\]::Max\(2000,\$DelayMs\)' -or
   $mainSource -match '\[Math\]::Max\(2000,\[int\]\$configObject\.Download\.DelayMs\)' -or
   $searchSource28 -match 'Download\.AllowParallel'){
    throw 'Worker- oder Basisabstandsbegrenzung ist weiterhin im produktiven Code enthalten.'
}

if($databaseSource -notmatch 'function Acquire-FsDownloadApiSlot' -or
   $databaseSource -notmatch 'function Set-FsDownloadApiCooldown' -or
   $databaseSource -notmatch 'RecoverySlotsRemaining' -or
   $databaseSource -notmatch 'recovery_slots_remaining' -or
   $databaseSource -notmatch '\.download-gate' -or
   $searchSource28 -notmatch 'function Claim-FsDownloadTasks' -or
   $searchSource28 -notmatch 'function Complete-FsDownloadWorkItem' -or
   $searchSource28 -notmatch 'ClaimBatchSize' -or
   $searchSource28 -notmatch 'DelayCacheSeconds' -or
   $searchSource28 -notmatch 'Download-Ergebnis atomar speichern'){
    throw 'HF60 reduziert die SQLite-Schreibkonkurrenz nicht durch Dateigate, Block-Claim, atomaren Abschluss und Delay-Cache.'
}

if($searchSource28 -notmatch '\$script:FsDownloadClaimQueues\s*=\s*@\{\}' -or
   $searchSource28 -notmatch '\$script:FsDownloadDelayCache\s*=\s*@\{\}' -or
   $searchSource28 -notmatch "Get-Variable -Name 'FsDownloadClaimQueues' -Scope Script"){
    throw 'HF60 initialisiert Download-Claim-Queue oder Delay-Cache unter StrictMode nicht pro Workerprozess.'
}



# HF65 production regression: download claim uses separate partial queue lanes,
# batches claims and returns the media snapshot needed by the worker.
$coreSource54=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1'))
$hf55ClaimBlock=[regex]::Match(
    $searchSource28,
    '(?s)function\s+Claim-FsDownloadTasks\s*\{.*?\n\}'
).Value
$hf55ClaimExecutable=(($hf55ClaimBlock -split "`r?`n") | Where-Object {
    $_ -notmatch '^\s*--' -and $_ -notmatch '^\s*#'
}) -join "`n"
if([string]::IsNullOrWhiteSpace($hf55ClaimBlock) -or
   $hf55ClaimExecutable -notmatch 'INDEXED BY ix_project_downloads_pending' -or
   $hf55ClaimExecutable -notmatch 'INDEXED BY ix_project_downloads_failed_retry' -or
   $hf55ClaimExecutable -notmatch 'd\.bytes AS download_bytes' -or
   $hf55ClaimExecutable -notmatch 'AS is_rejected' -or
   $hf55ClaimExecutable -match 'ORDER BY pd\.rowid'){
    throw 'HF65 Download-Claim verwendet nicht die partiellen Pending/Retry-Indizes samt Worker-Prefetch.'
}
if($databaseSource -notmatch 'ix_project_downloads_pending' -or
   $databaseSource -notmatch 'ix_project_downloads_failed_retry' -or
   $workerSource -notmatch '__FS_RETRY__'){
    throw 'HF65 Claim-Indizes oder konfliktfreier Worker-Retry fehlen.'
}
if($workerSource -notmatch 'Reset-FsWorkerTasks.+-Stage \$TaskType' -or
   $coreSource54 -notmatch 'Reset-FsWorkerTasks.+-Stage \$Stage'){
    throw 'HF60 begrenzt Worker-Aufräumarbeiten nicht auf die aktive Stufe.'
}
if($coreSource54 -notmatch '\$downloadAutoTuneEnabled' -or
   $coreSource54 -notmatch '\$Stage -eq ''download'' -and \$downloadAutoTuneEnabled'){
    throw 'HF60 unterdrückt download_tuning-Polling bei deaktiviertem AutoTune nicht.'
}


# HF60: Resolve already available media before starting download workers.
# The fast path must cover exact global rows and SHA1-equivalent rows in bulk,
# while real HTTP work remains on the ordinary worker/gate path.
if($searchSource28 -notmatch 'function Invoke-FsDownloadReuseFastPath' -or
   $searchSource28 -notmatch 'fs_download_reuse_direct' -or
   $searchSource28 -notmatch 'fs_download_reuse_hash' -or
   $searchSource28 -notmatch 'sd\.verified_sha1=tm\.sha1' -or
   $databaseSource -notmatch 'ix_downloads_verified_sha1' -or
   $searchSource28 -notmatch '\[DOWNLOAD-REUSE\]' -or
   $searchSource28 -notmatch 'Invoke-FsDownloadReuseFastPath.+ProjectId \$ProjectId' -or
   $searchSource28 -notmatch 'ReuseBatchSize' -or
   $searchSource28 -notmatch '-ExecutionTimeoutMs 60000 -ProgressLabel \("Download-Aufgaben blockweise beanspruchen;' -or
   $searchSource28 -notmatch '-ExecutionTimeoutMs 60000 -ProgressLabel \("Download-Ergebnis atomar speichern:'){
    throw 'HF60-Reuse-Fast-Path oder verlängerte kurze Download-DB-Operationen fehlen.'
}

# HF60: SQLITE_IOERR is treated as transient infrastructure damage first,
# retried with bounded backoff, and event logging is best-effort so a logging
# failure cannot terminate an otherwise recoverable run.
if($databaseSource -notmatch "retryKind='io'" -or
   $databaseSource -notmatch 'disk I/O error\|SQLITE_IOERR' -or
   $databaseSource -notmatch '\[Math\]::Min\(3,\$BusyRetries\)' -or
   $databaseSource -notmatch 'Ereignisprotokoll vorübergehend nicht schreibbar' -or
   $searchSource28 -notmatch 'disk I/O error\|SQLITE_IOERR'){
    throw 'HF60-I/O-Fehlerbehandlung ist nicht vollständig aktiv.'
}

# Hotfix 60: central session telemetry, deterministic delay reduction,
# 429-only increases, novice-readable progress and read-only GUI charts.
$coreSource30=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1'))
$monitorPath30=Join-Path $PSScriptRoot 'Show-FindSeriesDownloadMonitor.ps1'
$monitorSource30=[IO.File]::ReadAllText($monitorPath30)
if($coreSource30 -notmatch '\(\$sampleNow-\$lastTunePersistAt\)\.TotalSeconds -ge 30' -or
   $coreSource30 -notmatch '\(\$sampleNow-\$lastTuneLiveSampleAt\)\.TotalSeconds -ge 60'){
    throw 'HF60 schreibt laufende Autotune-Telemetrie weiterhin zu häufig.'
}
if($searchSource28 -notmatch 'function Initialize-FsDownloadAutoTune' -or
   $searchSource28 -notmatch 'function Complete-FsDownloadAutoTuneWindow' -or
   $searchSource28 -notmatch 'function Update-FsDownloadAutoTuneProgress' -or
   $searchSource28 -notmatch 'function Register-FsDownloadAutoTuneThrottle' -or
   $searchSource28 -notmatch 'function Get-FsDownloadDelayIncreaseAmount' -or
   $searchSource28 -notmatch 'function Get-FsDownloadDelayDecreaseAmount' -or
   $searchSource28 -notmatch 'BurstRecoverySuccesses' -or
   $searchSource28 -notmatch 'BurstRecoverySeconds' -or
   $searchSource28 -notmatch 'DelayIncreasePercent' -or
   $searchSource28 -notmatch 'DelayDecreasePercent' -or
   $searchSource28 -notmatch 'window_target=100' -or
   $searchSource28 -notmatch 'function Get-FsDownloadAutoTuneMinDelayMs' -or
   $searchSource28 -notmatch 'function Get-FsDownloadAutoTuneMinImprovementPct' -or
   $searchSource28 -notmatch 'Kein ausreichender Durchsatzgewinn' -or
   $searchSource28 -notmatch 'AutoTune-Floor' -or
   $searchSource28 -notmatch 'ThrottleBurstStarted' -or
   $searchSource28 -notmatch 'ForcedPauseSeconds' -or
   $searchSource28 -notmatch 'DelayIncreaseMs' -or
   $searchSource28 -notmatch 'burst_open' -or
   $searchSource28 -notmatch 'throttle_bursts' -or
   $searchSource28 -notmatch 'RetryAfterSeconds' -or
   $searchSource28 -notmatch '20\.\.100 ms' -or
   $searchSource28 -notmatch 'ThrottlePauseSeconds' -or
   $searchSource28 -notmatch 'ThrottleCarryoverSeconds'){
    throw 'HF66-Anfragesteuerung: 429-Schutz oder durchsatzsensitives AutoTune fehlt.'
}
if($databaseSource -notmatch 'function Ensure-FsDownloadTuningSchema' -or
   $databaseSource -notmatch 'run_start_terminal' -or
   $databaseSource -notmatch 'CREATE TABLE IF NOT EXISTS download_tuning_samples'){
    throw 'HF60-Telemetrieschema oder Session-Baseline fehlt.'
}
if($coreSource30 -notmatch 'Bilder herunterladen.+läuft' -or
   $coreSource30 -notmatch 'Dateien verarbeitet' -or
   $coreSource30 -notmatch 'dieser Lauf:' -or
   $coreSource30 -notmatch '\[ANFRAGESTEUERUNG\]' -or
   $coreSource30 -notmatch 'Complete-FsDownloadAutoTuneWindow' -or
   $coreSource30 -notmatch 'Restzeit' -or
   $coreSource30 -match '; ETA '){
    throw 'HF60-Fortschrittsanzeige ist nicht laienverständlich oder die zentrale Steuerung fehlt.'
}
if(-not(Test-Path -LiteralPath $monitorPath30 -PathType Leaf) -or
   $monitorSource30 -notmatch 'System.Windows.Forms.DataVisualization' -or
   $monitorSource30 -notmatch 'Anfrageabstand über die Zeit' -or
   $monitorSource30 -notmatch 'Neue Downloads pro Sekunde'){
    throw 'Grafischer HF60-Download-Monitor fehlt oder enthält keine Zeitreihen-Charts.'
}
if($monitorSource30 -match "MAX\(10\.0,MIN\(600\.0,\(julianday" -or
   $monitorSource30 -notmatch 'windowStartUtc' -or
   $monitorSource30 -notmatch 'elapsedSeconds=\[Math\]::Max'){
    throw 'HF60-Monitor verwendet weiterhin die fehlerhafte verschachtelte julianday-Abfrage.'
}
if($monitorSource30 -notmatch '\[int\]\$RefreshSeconds=10' -or
   $monitorSource30 -notmatch 'LastSamplesRead' -or
   $monitorSource30 -notmatch 'Expand-FsMonitorRows' -or
   $monitorSource30 -notmatch 'Get-FsMonitorScalar' -or
   $monitorSource30 -notmatch 'Charting\.DataPoint' -or
   $monitorSource30 -notmatch 'YValues=\[double\[\]\]' -or
   $monitorSource30 -notmatch '\.timeout 10000' -or
   $monitorSource30 -notmatch 'ExecutionTimeoutMs=20000' -or
   $mainSource -notmatch 'AddSeconds\(20\)' -or
   $monitorSource30 -notmatch 'BusyRetries=3' -or
   $monitorSource30 -notmatch 'download-monitor\.log' -or
   $monitorSource30 -notmatch 'System\.Windows\.Forms\.TextBox' -or
   $monitorSource30 -notmatch '-readonly -batch -bail' -or
   $monitorSource30 -notmatch 'PRAGMA query_only=ON' -or
   $monitorSource30 -match 'Ensure-FsDownloadTuningSchema' -or
   $monitorSource30 -match 'Import-Module .*FindSeries\.(Database|Core|Api|Search)' -or
   $monitorSource30 -notmatch 'Show-FsMonitorFatalError' -or
   $monitorSource30 -notmatch 'Gesamt:' -or
   $monitorSource30 -notmatch 'Download-Monitor Selbsttest: PASS' -or
   $mainSource -match '-WindowStyle Hidden' -or
   $mainSource -notmatch "'-Sta'" -or
   $mainSource -notmatch "'-ReadyFile'" -or
   $mainSource -notmatch "'-HideConsole'" -or
   $mainSource -notmatch 'Live-Ansicht sichtbar gestartet' -or
   $monitorSource30 -notmatch 'Write-FsMonitorReadyMarker' -or
   $monitorSource30 -notmatch 'Hide-FsMonitorConsoleWindow' -or
   $monitorSource30 -notmatch 'GetConsoleWindow' -or
   $monitorSource30 -notmatch 'ShowWindow' -or
   $mainSource -notmatch 'Stop-FsExistingDownloadMonitors' -or
   $mainSource -notmatch 'alte Monitorinstanz PID' -or
   $monitorSource30 -notmatch 'Set-FsDarkChartStyle' -or
   $monitorSource30 -notmatch '\[Drawing\.Color\]::Black' -or
   $monitorSource30 -notmatch 'time_segment_' -or
   $monitorSource30 -notmatch 'ChartType=.Line.' -or
   $monitorSource30 -notmatch 'Nine-column beeswarm' -or
   $monitorSource30 -notmatch 'one-sided columns' -or
   $monitorSource30 -notmatch 'Messung \{0\}' -or
   $monitorSource30 -notmatch 'AND run_id=\$runId' -or
   $monitorSource30 -notmatch 'CachedRunId' -or
   $databaseSource -notmatch 'ix_project_downloads_updated' -or
   $coreSource30 -notmatch 'TotalSeconds -ge 10' -or
   $coreSource30 -notmatch 'WorkerStartSpacingSeconds' -or
   $coreSource30 -notmatch 'Start-Sleep -Seconds \$initialStartSpacingSeconds' -or
   $monitorSource30 -notmatch "ScrollBars='None'" -or
   $monitorSource30 -notmatch "sample_type='live_current'" -or
   $monitorSource30 -notmatch 'Select-FsScatterRows' -or
   $monitorSource30 -notmatch "sample_type -in @\('live','window','recovery'\)" -or
   $monitorSource30 -notmatch '\$Samples=2000' -or
   $monitorSource30 -notmatch 'laufendes Teilfenster' -or
   $monitorSource30 -notmatch 'LiveSpacingSeconds 0' -or
   $monitorSource30 -notmatch 'reused/s' -or
   $monitorSource30 -notmatch 'MB/s vs\. Aufgaben/s' -or
   $monitorSource30 -notmatch 'MB/s vs\. neue Downloads/s' -or
   $monitorSource30 -notmatch 'Downloads/s vs\. Delay' -or
   $monitorSource30 -notmatch 'MB/s vs\. Delay' -or
   $monitorSource30 -notmatch 'Set-FsXYScatterPoints' -or
   $monitorSource30 -notmatch 'one-sided columns'){
    throw 'HF66-Monitor ist nicht read-only/dunkel/robust, verbindet Scatterpunkte nicht oder startet nicht sauber in STA.'
}

# Hotfix 24: The offline test must load the same API dependency as the
# orchestrator and workers before Search functions are exercised.
$categoryNormalizer=Get-Command -Name 'Normalize-FsCategoryTitle' -CommandType Function -ErrorAction SilentlyContinue
if($null -eq $categoryNormalizer){
    throw 'FindSeries.Api.psm1 wurde im Selbsttest nicht geladen; Normalize-FsCategoryTitle fehlt.'
}


# Hotfix 20: A SQLite JSON query with exactly one row is emitted by
# PowerShell as a scalar PSCustomObject. Neighbor and download workers must
# normalize it to Object[] before testing Length/indexing under StrictMode.
$searchModuleSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1'))
if($searchModuleSource -notmatch '\[object\[\]\]\$neighborRows\s*=\s*@\(Invoke-FsSqlite'){
    throw 'Neighbor-Worker normalisiert ein einzelnes SQLite-Ergebnis nicht zu Object[].'
}
if($searchModuleSource -notmatch '\[object\[\]\]\$downloadRows\s*=\s*@\(Invoke-FsSqlite'){
    throw 'Download-Worker normalisiert ein einzelnes SQLite-Ergebnis nicht zu Object[].'
}
[object[]]$singleRowShape=@([pscustomobject]@{id=1})
if($singleRowShape.Length -ne 1 -or [int]$singleRowShape[0].id -ne 1){
    throw 'PowerShell-5.1-Einzelzeilen-Normalisierung ist instabil.'
}

# Hotfix 24: DownloadFileTaskAsync failures must no longer be flattened to
# Task.Wait's generic AggregateException. The worker needs concrete HTTP/root
# errors, a shared download gate and targeted legacy repair.
if($searchModuleSource -match '\.Wait\(30000\)' -or
   $searchModuleSource -notmatch 'function Invoke-FsDownloadFileWithRetry' -or
   $searchModuleSource -notmatch 'Download-Timeout nach \$effectiveTimeoutSeconds Sekunden' -or
   $searchModuleSource -notmatch '\.GetAwaiter\(\)\.GetResult\(\)' -or
   $searchModuleSource -notmatch 'Acquire-FsDownloadApiSlot' -or
   $searchModuleSource -notmatch 'Set-FsDownloadApiCooldown' -or
   $searchModuleSource -notmatch 'HF23-Wait-Fehler gezielt reaktiviert'){
    throw 'Downloadpfad verwendet nicht den HF60-Retry-/Dateigate-/Fehlerentpackungs- und Reparaturpfad.'
}
$innerDownloadException=New-Object System.InvalidOperationException -ArgumentList 'inner-download-selftest'
$aggregateDownloadException=[System.AggregateException]::new([System.Exception[]]@($innerDownloadException))
$downloadExceptionInfo=Get-FsDownloadExceptionInfo -Exception $aggregateDownloadException
if([string]$downloadExceptionInfo.RootMessage -ne 'inner-download-selftest' -or [string]$downloadExceptionInfo.Message -notmatch 'inner-download-selftest'){
    throw 'Download-AggregateException wird nicht bis zur eigentlichen Ursache entpackt.'
}
if(-not(Test-FsInfrastructureTaskError -Message 'Download-Infrastruktur: HTTP 429 Too Many Requests')){
    throw 'Erschöpftes Download-Throttling stoppt die Worker nicht kontrolliert.'
}
if($searchModuleSource -notmatch '\[object\[\]\]\$downloadOutput\s*=\s*@\(Invoke-FsDownloadFileWithRetry' -or
   $searchModuleSource -notmatch 'function ConvertTo-FsDownloadTimingResult' -or
   $searchModuleSource -notmatch "PSObject\.Properties\['GateMs'\]" -or
   $searchModuleSource -notmatch 'Download-Timing-Ergebnis fehlt oder ist mehrdeutig'){
    throw 'HF60 normalisiert das Download-Timing-Ergebnis nicht robust gegen zusätzliche Pipelineausgaben.'
}
if($searchModuleSource -notmatch 'd\.bytes AS download_bytes' -or
   $searchModuleSource -match '\$m\.bytes\b' -or
   $searchModuleSource -notmatch "PSObject\.Properties\['download_bytes'\]"){
    throw 'HF60 liest downloads.bytes im produktiven Reuse-Pfad nicht StrictMode-sicher.'
}
if(-not(Test-FsInfrastructureTaskError -Message 'Die Eigenschaft "GateMs" wurde für dieses Objekt nicht gefunden.') -or
   -not(Test-FsInfrastructureTaskError -Message 'Die Eigenschaft "bytes" wurde für dieses Objekt nicht gefunden.')){
    throw 'HF60 behandelt frühere GateMs-/bytes-Telemetriefehler nicht als Infrastrukturfehler.'
}

# HF60: completed Resume runs use a verified metadata snapshot/task
# coverage and download seeding touches only not-yet-requested candidates.
if($databaseSource -notmatch 'function Ensure-FsSeedOptimizationSchema' -or
   $databaseSource -notmatch 'CREATE TABLE IF NOT EXISTS project_seed_state' -or
   $databaseSource -notmatch 'ix_metadata_tasks_level' -or
   $databaseSource -notmatch 'ix_metadata_tasks_media_cover' -or
   $databaseSource -notmatch 'ix_project_media_media_scan' -or
   $databaseSource -notmatch 'ix_project_media_download_seed'){
    throw 'HF60-Schema für schnelle Resume-Seed-Prüfungen fehlt.'
}
if($searchModuleSource -notmatch 'Taskabdeckung .* bestätigt' -or
   $searchModuleSource -notmatch 'verifizierter Projektzustand unverändert' -or
   $searchModuleSource -notmatch 'INDEXED BY ix_metadata_tasks_level' -or
   $searchModuleSource -notmatch 'INDEXED BY ix_project_media_media_scan' -or
   $searchModuleSource -notmatch 'INDEXED BY ix_metadata_tasks_media_cover' -or
   $searchModuleSource -notmatch 'Metadaten-Abdeckungsdelta lesen' -or
   $searchModuleSource -notmatch 'Schreibchunk mit .* überschritt 60 s' -or
   $searchModuleSource -notmatch 'Download-Fast-Path: neue Kandidaten prüfen' -or
   $searchModuleSource -notmatch 'kein Projektbestandsscan' -or
   $searchModuleSource -match 'Download-Projektbestand lesen'){
    throw 'HF60-Metadaten-/Download-Fast-Path ist nicht delta- und kandidatengesteuert.'
}
if($searchModuleSource -match 'FROM\s+fs_metadata_seed_ids\s+s\s+ON\s+CONFLICT' -or
   $searchModuleSource -match 'CREATE TEMP TABLE fs_metadata_seed_ids' -or
   $searchModuleSource -notmatch 'VALUES \$values\s+ON CONFLICT\(project_id,media_id\) DO UPDATE SET'){
    throw 'HF60-Metadaten-Seeding verwendet nicht den direkten VALUES-UPsert-Pfad für das Abdeckungsdelta.'
}
if($searchModuleSource -notmatch 'r\.page_id IS NOT NULL AND r\.page_id>0' -or
   $searchModuleSource -notmatch "r\.sha1 IS NOT NULL AND r\.sha1<>''" -or
   $searchModuleSource -notmatch "r\.normalized_title IS NOT NULL AND r\.normalized_title<>''"){
    throw 'HF60-Ablehnungsprüfung kann die partiellen media_rejections-Indizes nicht zuverlässig verwenden.'
}

# HF60 production regression: a normal INNER JOIN allowed SQLite to reorder the
# tiny seed batch behind a full scan of media. CROSS JOIN pins the intended
# loop order: bounded TEMP seed batch first, media rowid lookup second.
if($searchModuleSource -notmatch 'FROM fs_neighbor_seed_scan s\s+CROSS JOIN media m\s+WHERE m\.id=s\.media_id' -or
   $searchModuleSource -match 'FROM fs_neighbor_seed_scan s\s+JOIN media m ON m\.id=s\.media_id'){
    throw 'HF60-Nachbar-Seeding erzwingt den kleinen Seed-Batch nicht als äußere Join-Schleife.'
}
if($mainSource -notmatch 'Start-FsAutomaticDownloadMonitor' -or
   $mainSource -notmatch '\[switch\]\$NoMonitor' -or
   $mainSource -match '-WindowStyle Hidden' -or
   $mainSource -notmatch "'-Sta'" -or
   $mainSource -notmatch "'-ReadyFile'" -or
   $mainSource -notmatch "'-HideConsole'" -or
   $monitorSource30 -notmatch 'Write-FsMonitorReadyMarker' -or
   $monitorSource30 -notmatch 'Hide-FsMonitorConsoleWindow' -or
   $monitorSource30 -notmatch 'New-FsScatterChart' -or
   $monitorSource30 -notmatch 'Downloads/s vs\. Delay' -or
   $monitorSource30 -notmatch 'MB/s vs\. Delay' -or
   $monitorSource30 -notmatch 'Get-FsFalseColor' -or
   $monitorSource30 -notmatch 'FindSeriesDownloadMonitor_'){
    throw 'HF60-Autostart, Scatter-Plots oder Monitor-Einzelinstanz fehlen.'
}

if($searchModuleSource -notmatch "m\.url IS NOT NULL" -or
   $searchModuleSource -notmatch "m\.media_type IN \('BITMAP','DRAWING'\)" -or
   $searchModuleSource -notmatch "pd\.status='skipped'"){
    throw 'HF60-Download-Fast-Path verwendet nicht dieselben Qualifikationskriterien wie das Batch-Seeding.'
}

# HF60 regression: optimized seed functions must not truncate the remainder of
# FindSeries.Search.psm1. This explicitly protects query, metadata, neighbor,
# autotune and download workers in the cumulative drop-in.
foreach($requiredFunction in @(
    'Invoke-FsQueryWorkerItem',
    'Invoke-FsMetadataWorkerItem',
    'Invoke-FsNeighborWorkerItem',
    'Initialize-FsDownloadAutoTune',
    'Get-FsDownloadAutoTuneStatus',
    'Complete-FsDownloadAutoTuneWindow',
    'Register-FsDownloadAutoTuneThrottle',
    'Invoke-FsDownloadWorkerItem'
)){
    if($searchModuleSource -notmatch ("function\s+"+[regex]::Escape($requiredFunction)+"\s*\{")){
        throw "HF60-Regression: Funktion '$requiredFunction' fehlt in FindSeries.Search.psm1."
    }
}
if($searchModuleSource.Length -lt 150000 -or $searchModuleSource -notmatch 'Export-ModuleMember -Function \*-Fs\*'){
    throw 'HF60-Regression: FindSeries.Search.psm1 ist unvollständig oder abgeschnitten.'
}
if($searchModuleSource -notmatch "record_type='download_item'" -or
   $searchModuleSource -notmatch "operation='download-item'" -or
   -not(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Analyze-FindSeriesPerformance.ps1') -PathType Leaf)){
    throw 'HF60-Detailmessung oder parameterloses Performance-Auswerteskript fehlt.'
}
$monitorHasCompletedWindowFilter=(
    $monitorSource30 -match "sample_type\s+-eq\s+'window'" -or
    $monitorSource30 -match "sample_type\s+-in\s+@\('window','recovery'\)"
)
$getStatusSource46=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Get-FindSeriesStatus.ps1'))
if($databaseSource -notmatch 'last_window_delay_ms' -or
   $databaseSource -notmatch 'last_window_files_per_second' -or
   $searchModuleSource -notmatch 'HasCompletedWindow' -or
   $coreSource30 -notmatch 'Messung \(nur Information\): Fenster' -or
   $coreSource30 -notmatch 'Letztes vollständiges Fenster' -or
   $monitorSource30 -notmatch 'aktuelles Fenster' -or
   $monitorSource30 -notmatch 'LastWindowDelayMs' -or
   $monitorSource30 -notmatch 'LastWindowFilesPerSecond' -or
   $monitorSource30 -notmatch 'Letztes vollständiges Fenster' -or
   $monitorSource30 -notmatch "sample_type='live_current'" -or
   -not $monitorHasCompletedWindowFilter -or
   $getStatusSource46 -notmatch 'Schnellstes gemessenes Fenster'){
    throw 'HF60 trennt aktuelles, letztes vollständiges und bestes Messfenster nicht eindeutig.'
}


# Hotfix 22: Neighbor results must use the bounded set-based writer. The old
# per-record SQL repeated identity lookups many times and could hold the global
# write lock for more than five minutes on a 224k-media workspace.
if($searchModuleSource -notmatch 'function Invoke-FsNeighborResultBulkWrite' -or
   $searchModuleSource -notmatch 'Neighbor-Ergebnisse schreiben' -or
   $searchModuleSource -notmatch '-ExecutionTimeoutMs 30000' -or
   $searchModuleSource -notmatch '\$neighborWrite=Invoke-FsNeighborResultBulkWrite'){
    throw 'Neighbor-Worker verwendet nicht den begrenzten set-basierten Bulk-Schreibpfad.'
}
if($searchModuleSource -notmatch "status IN \('pending','running','failed'\)" -or
   $searchModuleSource -notmatch 'INDEXED BY ix_metadata_tasks_queue'){
    throw 'Metadaten-Fast-Path prüft offene Tasks nicht über den Queue-Index.'
}

# Hotfix 18: Commons may omit query.redirects, query.pages or even the
# complete query node. The helper must always expose stable Object[] values;
# Windows PowerShell 5.1 must not collapse an empty array to $null.
$metadataShape=Get-FsMetadataResponseCollections -Response ([pscustomobject]@{
    query=[pscustomobject]@{
        pages=@([pscustomobject]@{pageid=1;title='File:Selftest.jpg'})
    }
})
$metadataPages=@($metadataShape.Pages)
$metadataRedirects=@($metadataShape.Redirects)
if($metadataPages.Count -ne 1 -or $metadataRedirects.Count -ne 0){
    throw ("Optionale Commons-Metadatenfelder instabil: Pages={0}; Redirects={1}." -f $metadataPages.Count,$metadataRedirects.Count)
}
$emptyMetadataShape=Get-FsMetadataResponseCollections -Response ([pscustomobject]@{})
$emptyPages=@($emptyMetadataShape.Pages)
$emptyRedirects=@($emptyMetadataShape.Redirects)
if($emptyPages.Count -ne 0 -or $emptyRedirects.Count -ne 0){
    throw ("Leere Commons-Metadatenantwort instabil: Pages={0}; Redirects={1}." -f $emptyPages.Count,$emptyRedirects.Count)
}


# Hotfix 18: Metadata requests use compact page IDs whenever possible. Only
# legacy rows without page_id use title requests, split by encoded URI length.
$pagePlanTasks=New-Object Collections.ArrayList
$pagePlanRows=New-Object Collections.ArrayList
foreach($n in 1..50){
    [void]$pagePlanTasks.Add([pscustomobject]@{media_id=$n})
    [void]$pagePlanRows.Add([pscustomobject]@{id=$n;page_id=(9000000+$n);request_title=('File:'+('Sehr langer Titel '*20)+$n+'.jpg')})
}
$pagePlan=Get-FsMetadataRequestGroups -Tasks ([object[]]$pagePlanTasks.ToArray()) -MediaRows ([object[]]$pagePlanRows.ToArray()) -MaxTitles 50 -MaxEncodedTitleChars 3500
if(@($pagePlan.Groups).Count -ne 1 -or [string]$pagePlan.Groups[0].Mode -ne 'pageids' -or @($pagePlan.Groups[0].Tasks).Count -ne 50){
    throw 'Metadaten-Plan verwendet für 50 bekannte Commons-Seiten nicht genau einen kompakten pageids-Request.'
}
$titlePlanTasks=New-Object Collections.ArrayList
$titlePlanRows=New-Object Collections.ArrayList
foreach($n in 1..20){
    [void]$titlePlanTasks.Add([pscustomobject]@{media_id=$n})
    [void]$titlePlanRows.Add([pscustomobject]@{id=$n;page_id=0;request_title=('File:'+('Äußerst langer Titel mit Leerzeichen '*18)+$n+'.jpg')})
}
$titlePlan=Get-FsMetadataRequestGroups -Tasks ([object[]]$titlePlanTasks.ToArray()) -MediaRows ([object[]]$titlePlanRows.ToArray()) -MaxTitles 50 -MaxEncodedTitleChars 3500
if(@($titlePlan.Groups).Count -le 1){throw 'Lange title-Fallbacks wurden nicht nach URI-Länge geteilt.'}
foreach($group in @($titlePlan.Groups)){
    if([string]$group.Mode -ne 'titles'){throw 'Title-Fallback wurde mit einem falschen Requestmodus geplant.'}
    $joined=(@($group.Rows|ForEach-Object{[string]$_.request_title})) -join '|'
    if(([Uri]::EscapeDataString($joined)).Length -gt 3800 -and @($group.Tasks).Count -gt 1){throw 'Geplanter title-Fallback ist weiterhin zu lang.'}
}
if(-not(Test-FsUriTooLongError -Message 'Der Remoteserver hat einen Fehler zurückgegeben: (414) URI Too Long.')){throw 'HTTP-414-Erkennung ist nicht aktiv.'}

# Local workspace configuration must be honored, while an explicit parameter wins.
$configTestRoot=Join-Path $env:TEMP ('FindSeriesV5-ConfigTest-'+[Guid]::NewGuid().ToString('N'))
try {
    $configTestDir=Join-Path $configTestRoot 'Config'
    New-Item -ItemType Directory -Path $configTestDir -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $configTestDir 'local.json'),'{"Workspace":"ConfiguredWorkspace"}',(New-Object Text.UTF8Encoding($false)))
    $configured=Resolve-FsConfiguredWorkspace -ApplicationRoot $configTestRoot
    $expectedConfigured=[IO.Path]::GetFullPath((Join-Path $configTestRoot 'ConfiguredWorkspace'))
    if($configured -ne $expectedConfigured){throw 'Config\local.json wurde nicht als Workspace-Default verwendet.'}
    $explicit=Resolve-FsConfiguredWorkspace -Workspace (Join-Path $configTestRoot 'ExplicitWorkspace') -ApplicationRoot $configTestRoot
    $expectedExplicit=[IO.Path]::GetFullPath((Join-Path $configTestRoot 'ExplicitWorkspace'))
    if($explicit -ne $expectedExplicit){throw 'Expliziter Workspace überschreibt Config\local.json nicht.'}
} finally {
    Remove-Item -LiteralPath $configTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$created = -not (Test-Path -LiteralPath $Workspace)
try {
    $init=Initialize-FsDatabase -Workspace $Workspace -SqlitePath $SqlitePath
    $sqlite=$init.SqlitePath;$db=$init.Paths.Database
    $config=Get-FsProjectConfig -Profile 'Fast' -ProfilesPath (Join-Path $PSScriptRoot 'Config\profiles.json')
    $project=Save-FsProject -SqlitePath $sqlite -DatabasePath $db -Name 'Self Test' -Slug 'self-test' -Profile 'Fast' -Language 'de' -ConfigJson ($config|ConvertTo-Json -Depth 20 -Compress)
    $projectId=[int]$project.id
    $config.Diagnostics.Profile=$true;$config.Diagnostics.Console=$false;$config.Diagnostics.OutputFile='Diagnostics\selftest-performance.csv'
    $profileFile=Initialize-FsDiagnostics -Config $config -Workspace $init.Paths.Root -ProjectId $projectId -RunId 777 -Worker 'selftest' -Stage 'selftest'
    Write-FsPerformanceRecord -Record @{record_type='selftest';operation='csv';total_ms=1;success=$true}
    if(-not(Test-Path -LiteralPath $profileFile -PathType Leaf)){throw 'Profiling-CSV wurde nicht erzeugt.'}

    # Exklusiver Projekt-Lock und Bereinigung veralteter Runs.
    $projectLock=Open-FsProjectRunLock -Workspace $init.Paths.Root -ProjectId $projectId -ProjectName 'Self Test'
    try {
        $secondLockFailed=$false
        $unexpected=$null
        try { $unexpected=Open-FsProjectRunLock -Workspace $init.Paths.Root -ProjectId $projectId -ProjectName 'Self Test' } catch { $secondLockFailed=$true }
        finally { if($null -ne $unexpected){Close-FsProjectRunLock -Lock $unexpected} }
        if(-not $secondLockFailed){throw 'Exklusiver Projekt-Lock verhindert keinen Doppelstart.'}
    } finally { Close-FsProjectRunLock -Lock $projectLock }
    $staleRun=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode 'Resume' -Profile 'Fast' -ParametersJson '{}'
    if((Stop-FsStaleRuns -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId) -lt 1){throw 'Veralteter Run wurde nicht bereinigt.'}
    if(Test-FsRunActive -SqlitePath $sqlite -DatabasePath $db -RunId $staleRun){throw 'Bereinigter Run ist weiterhin aktiv.'}

    # HF60 monitor-rate regression: the monitor window query must be a
    # simple indexed timestamp comparison and execute successfully in SQLite.
    $monitorWindowStart=[DateTime]::UtcNow.AddMinutes(-10).ToString('o')
    $monitorRateRows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT COUNT(*) completed FROM project_downloads INDEXED BY ix_project_downloads_updated WHERE project_id=$projectId AND updated_at >= $(ConvertTo-FsSqlLiteral $monitorWindowStart) AND status IN ('done','reused','failed','skipped');")
    if($monitorRateRows.Count -ne 1 -or $null -eq $monitorRateRows[0].completed){throw 'HF60-Monitor-Zeitfensterabfrage ist nicht SQLite-kompatibel.'}

    # HF65-Anfragesteuerung: first window establishes a baseline. Further
    # reductions require a measurable throughput gain and may never cross the
    # configured floor. 429 handling remains asymmetric and conservative.
    $tuneRun=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode 'Download' -Profile 'Fast' -ParametersJson '{}'
    $config.Download.AutoTune=$true
    $config.Download.DelayMs=400
    $config.Download.AutoTuneMinDelayMs=250
    $config.Download.AutoTuneMinImprovementPct=2
    $tuneInitial=Initialize-FsDownloadAutoTune -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db
    if($null -eq $tuneInitial -or -not$tuneInitial.Enabled -or [int]$tuneInitial.CurrentDelayMs -ne 400){throw 'Anfragesteuerung wurde nicht mit dem konfigurierten Startdelay initialisiert.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "UPDATE download_tuning SET window_target=3 WHERE project_id=$projectId;"|Out-Null

    [void](Update-FsDownloadAutoTuneProgress -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -Successes 2 -Bytes 2097152 -ElapsedMs 1000 -WriteLiveSample)
    [void](Complete-FsDownloadAutoTuneWindow -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -Successes 3 -Bytes 3145728 -ElapsedMs 1500)
    $tuneAfterFirstWindow=Get-FsDownloadAutoTuneStatus -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db
    if([int]$tuneAfterFirstWindow.CurrentDelayMs -ne 360 -or [int]$tuneAfterFirstWindow.WindowSuccesses -ne 0){throw 'HF60 hat 400 ms nicht proportional um 40 ms reduziert.'}
    if([string]$tuneAfterFirstWindow.LastChangeReason -notmatch 'Basisfenster'){
        throw 'HF65 kennzeichnet das erste AutoTune-Fenster nicht als Baseline.'
    }

    # Deliberately slower second window: HF65 must HOLD 360 ms instead of
    # blindly reducing the request interval.
    [void](Complete-FsDownloadAutoTuneWindow -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -Successes 3 -Bytes 1048576 -ElapsedMs 3000)
    $tuneAfterSlowWindow=Get-FsDownloadAutoTuneStatus -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db
    if([int]$tuneAfterSlowWindow.CurrentDelayMs -ne 360 -or [int]$tuneAfterSlowWindow.Direction -ne 0 -or [int]$tuneAfterSlowWindow.HoldWindows -lt 1){
        throw 'HF65 reduziert das Delay trotz fehlendem Durchsatzgewinn.'
    }
    if([int]$tuneAfterSlowWindow.BestDelayMs -ne 400 -or [Math]::Abs([double]$tuneAfterSlowWindow.BestFilesPerSecond-2.0) -gt 0.0001){
        throw 'HF65 hat die Telemetrie des schnellsten Fensters beschädigt.'
    }

    # A clearly faster window may resume exploration and reduce 360 -> 324 ms.
    [void](Complete-FsDownloadAutoTuneWindow -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -Successes 3 -Bytes 3145728 -ElapsedMs 1200)
    $tuneAfterFastWindow=Get-FsDownloadAutoTuneStatus -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db
    if([int]$tuneAfterFastWindow.CurrentDelayMs -ne 324 -or [int]$tuneAfterFastWindow.Direction -ne -1 -or [int]$tuneAfterFastWindow.HoldWindows -ne 0){
        throw 'HF65 setzt die Delay-Erkundung trotz deutlichem Durchsatzgewinn nicht fort.'
    }

    $config.Download.ThrottlePauseSeconds=20
    $config.Download.ThrottleCarryoverSeconds=900
    $config.Download.WorkerStartSpacingSeconds=15
    $config.Download.BurstRecoverySuccesses=8
    $config.Download.BurstRecoverySeconds=20
    $config.Download.RecoveryWorkerSpacingMs=150
    if((Get-FsWorkerStartSpacingSeconds -Config $config -Stage 'download') -ne 15 -or (Get-FsWorkerStartSpacingSeconds -Config $config -Stage 'category') -ne 0){
        throw 'HF60 staffelt initiale Download-Worker nicht exakt im Abstand von 15 Sekunden.'
    }

    $firstThrottle=Register-FsDownloadAutoTuneThrottle -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -StatusCode 429 -Note 'selftest'
    if($null -eq $firstThrottle -or -not[bool]$firstThrottle.ThrottleBurstStarted -or [int]$firstThrottle.ForcedPauseSeconds -ne 20 -or [int]$firstThrottle.BurstNumber -ne 1){
        throw 'HF60 kennzeichnet den ersten 429-Burst nicht mit 20-Sekunden-Zwangspause.'
    }
    if([int]$firstThrottle.CurrentDelayMs -ne 405 -or [int]$firstThrottle.DelayIncreaseMs -ne 81 -or [int]$firstThrottle.Total429 -ne 1 -or [int]$firstThrottle.HoldWindows -ne 0){
        throw 'HF60 erhöht 324 ms bei HTTP 429 nicht gemäßigt auf 405 ms oder aktiviert noch alte Schutzfenster.'
    }

    $secondThrottle=Register-FsDownloadAutoTuneThrottle -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -StatusCode 429 -Note 'same burst'
    if([bool]$secondThrottle.ThrottleBurstStarted -or [int]$secondThrottle.CurrentDelayMs -ne 405 -or [int]$secondThrottle.Total429 -ne 2 -or [int]$secondThrottle.BurstNumber -ne 1 -or [int]$secondThrottle.ForcedPauseSeconds -ne 20){
        throw 'Parallele HTTP-429-Antworten erzeugen weiterhin künstlich neue Bursts, Delay-Sprünge oder längere Pausen.'
    }

    # 7 Erfolge reichen selbst nach 20 Sekunden nicht.
    $old429=(Get-FsUnixMilliseconds)-21000
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "UPDATE download_tuning SET last_429_at_ms=$old429,cooldown_until_ms=0 WHERE project_id=$projectId;"|Out-Null
    [void](Update-FsDownloadAutoTuneProgress -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -Successes 7 -Bytes 1024 -ElapsedMs 21000)
    $notRecovered=Get-FsDownloadAutoTuneStatus -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db
    if(-not[bool]$notRecovered.BurstOpen -or [int]$notRecovered.CurrentDelayMs -ne 405){throw 'HF60 schließt einen 429-Burst bereits vor 8 erfolgreichen Dateien.'}

    # Bei 8 Erfolgen und 20 Sekunden Ruhe wird sofort reduziert.
    [void](Update-FsDownloadAutoTuneProgress -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -Successes 8 -Bytes 2048 -ElapsedMs 22000)
    $recovered=Get-FsDownloadAutoTuneStatus -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db
    if([bool]$recovered.BurstOpen -or [int]$recovered.CurrentDelayMs -ne 364 -or [int]$recovered.HoldWindows -ne 0){
        throw 'HF60 reduziert nach 8 Erfolgen und 20 Sekunden Ruhe nicht unmittelbar von 405 auf 364 ms.'
    }

    # Ein echter Folgeburst bleibt moderat und nutzt ebenfalls nur 20 Sekunden.
    $thirdThrottle=Register-FsDownloadAutoTuneThrottle -ProjectId $projectId -RunId $tuneRun -Config $config -SqlitePath $sqlite -DatabasePath $db -StatusCode 429 -Note 'second burst'
    if(-not[bool]$thirdThrottle.ThrottleBurstStarted -or [int]$thirdThrottle.BurstNumber -ne 2 -or [int]$thirdThrottle.CurrentDelayMs -ne 455 -or [int]$thirdThrottle.DelayIncreaseMs -ne 91 -or [int]$thirdThrottle.ForcedPauseSeconds -ne 20){
        throw 'HF60 behandelt einen echten zweiten Burst nicht mit moderatem Schritt und 20-Sekunden-Pause.'
    }

    # Ein unmittelbar anschließender neuer Run übernimmt nur den aktuellen
    # Sicherheitszustand; Messwerte und 429-Zähler beginnen leer.
    $carryRun=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode 'Download' -Profile 'Fast' -ParametersJson '{}'
    $carry=Initialize-FsDownloadAutoTune -ProjectId $projectId -RunId $carryRun -Config $config -SqlitePath $sqlite -DatabasePath $db
    if([int]$carry.CurrentDelayMs -ne 455 -or -not[bool]$carry.BurstOpen -or [int]$carry.Total429 -ne 0 -or [int]$carry.RunId -ne $carryRun){
        throw 'HF60 übernimmt eine aktuelle 429-Schutzlage über den Neustart nicht korrekt.'
    }
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "UPDATE download_tuning SET burst_open=0,cooldown_until_ms=0,last_429_at_ms=0,last_429_at=NULL WHERE project_id=$projectId;"|Out-Null
    Remove-Item -LiteralPath ($db+'.download-gate') -Force -ErrorAction SilentlyContinue
    # HF60 download gate is file-based and therefore does not consume SQLite's
    # single writer slot before every HTTP request.
    $downloadGatePath=$db+'.download-gate'
    Remove-Item -LiteralPath $downloadGatePath -Force -ErrorAction SilentlyContinue
    $downloadSlot1=Acquire-FsDownloadApiSlot -DatabasePath $db -DelayMs 120
    $downloadSlot2=Acquire-FsDownloadApiSlot -DatabasePath $db -DelayMs 120
    if(-not(Test-Path -LiteralPath $downloadGatePath -PathType Leaf) -or [int]$downloadSlot2.WaitMs -lt 20){
        throw 'HF60-Dateigate serialisiert Downloadstarts nicht unabhängig von SQLite.'
    }
    [void](Set-FsDownloadApiCooldown -DatabasePath $db -Seconds 1 -RecoverySlots 2 -RecoverySpacingMs 150)
    $downloadGateState=(Get-Content -LiteralPath $downloadGatePath -Raw)|ConvertFrom-Json
    if([long]$downloadGateState.cooldown_until_ms -le (Get-FsUnixMilliseconds) -or [int]$downloadGateState.recovery_slots_remaining -ne 2){
        throw 'HF60-Dateigate speichert Pause und endliche Recovery-Slots nicht.'
    }
    $recoverySlot1=Acquire-FsDownloadApiSlot -DatabasePath $db -DelayMs 0 -RecoverySpacingMs 150
    $recoverySlot2=Acquire-FsDownloadApiSlot -DatabasePath $db -DelayMs 0 -RecoverySpacingMs 150
    $normalSlot=Acquire-FsDownloadApiSlot -DatabasePath $db -DelayMs 0 -RecoverySpacingMs 150
    if(-not[bool]$recoverySlot1.RecoverySlot -or -not[bool]$recoverySlot2.RecoverySlot -or [bool]$normalSlot.RecoverySlot -or [int]$normalSlot.WaitMs -gt 80){
        throw 'HF60 beendet die Recovery-Staffelung nicht nach der einmaligen Worker-Welle.'
    }

    # HF60 runtime regression: execute the real download function against a
    # local file URI. A deliberately noisy heartbeat must not pollute the
    # timing return object or make GateMs/HttpMs inaccessible.
    Remove-Item -LiteralPath $downloadGatePath -Force -ErrorAction SilentlyContinue
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "UPDATE download_tuning SET current_delay_ms=0,burst_open=0,cooldown_until_ms=0 WHERE project_id=$projectId;"|Out-Null
    $hf48Source=Join-Path $init.Paths.Root 'hf48-timing-source.bin'
    $hf48Destination=Join-Path $init.Paths.Root 'hf48-timing-destination.bin'
    [IO.File]::WriteAllBytes($hf48Source,[byte[]](1,2,3,4,5,6,7,8))
    $hf48Uri=([Uri]$hf48Source).AbsoluteUri
    $hf48NoisyHeartbeat={Write-Output 'heartbeat-noise'}.GetNewClosure()
    [object[]]$hf48DownloadOutput=@(Invoke-FsDownloadFileWithRetry -Uri $hf48Uri -Destination $hf48Destination -Headers @{} -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -RunId $tuneRun -MediaId 999991 -Worker 'hf48-timing-test' -Config $config -Heartbeat $hf48NoisyHeartbeat -DelayMs 0 -Retries 1 -TimeoutSeconds 30)
    $hf48TimingResult=ConvertTo-FsDownloadTimingResult -Output $hf48DownloadOutput
    # Zusätzliche legitime Success-Stream-Ausgaben sind zulässig. Entscheidend
    # ist das eine kanonische Timingobjekt mit vollständigem Pflichtfeldsatz.
    if($null -eq $hf48TimingResult -or [long]$hf48TimingResult.Bytes -ne 8){
        throw ("HF60 Download-Timingobjekt fehlt oder enthält eine falsche Bytezahl; Output={0}." -f $hf48DownloadOutput.Count)
    }
    Remove-Item -LiteralPath $hf48Source,$hf48Destination -Force -ErrorAction SilentlyContinue

    # HF60 runtime regression: the previous production crash occurred before
    # the HTTP path when an already completed download was reused. Execute the
    # real worker-item path with downloads.bytes present only on the joined
    # downloads row; StrictMode must not look for a nonexistent media.bytes.
    $hf50Now=Get-FsUtcNowText
    $hf50ReuseTitle='File:HF60 reuse bytes regression.jpg'
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
INSERT INTO media(title,normalized_title,canonical_title,url,media_type,created_at,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $hf50ReuseTitle),$(ConvertTo-FsSqlLiteral $hf50ReuseTitle),$(ConvertTo-FsSqlLiteral $hf50ReuseTitle),'https://example.invalid/hf50-reuse.jpg','BITMAP',$(ConvertTo-FsSqlLiteral $hf50Now),$(ConvertTo-FsSqlLiteral $hf50Now));
INSERT INTO downloads(media_id,status,local_path,bytes,historical_complete,owner_project_id,created_at,updated_at)
SELECT id,'done','E:\Temp\hf50-reuse-existing.jpg',1234,1,$projectId,$(ConvertTo-FsSqlLiteral $hf50Now),$(ConvertTo-FsSqlLiteral $hf50Now)
FROM media WHERE title=$(ConvertTo-FsSqlLiteral $hf50ReuseTitle);
INSERT INTO project_downloads(project_id,media_id,status,updated_at)
SELECT $projectId,id,'pending',$(ConvertTo-FsSqlLiteral $hf50Now)
FROM media WHERE title=$(ConvertTo-FsSqlLiteral $hf50ReuseTitle);
"@|Out-Null
    $hf50ReuseMedia=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT id FROM media WHERE title=$(ConvertTo-FsSqlLiteral $hf50ReuseTitle);")
    if($hf50ReuseMedia.Count -ne 1){throw 'HF60-Reuse-Testmedium wurde nicht eindeutig angelegt.'}
    $hf50ReuseResult=Invoke-FsDownloadWorkerItem -ProjectId $projectId -RunId $tuneRun -Worker 'hf50-reuse-worker' -Config $config -SqlitePath $sqlite -DatabasePath $db -MediaRoot (Join-Path $init.Paths.Root 'Media') -Headers @{}
    $hf50ReuseState=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT pd.status,d.status global_status,d.bytes FROM project_downloads pd JOIN downloads d ON d.media_id=pd.media_id WHERE pd.project_id=$projectId AND pd.media_id=$([int]$hf50ReuseMedia[0].id);")
    if(-not[bool]$hf50ReuseResult -or $hf50ReuseState.Count -ne 1 -or
       [string]$hf50ReuseState[0].status -ne 'reused' -or
       [string]$hf50ReuseState[0].global_status -ne 'done' -or
       [long]$hf50ReuseState[0].bytes -ne 1234){
        throw 'HF60 produktiver Reuse-Pfad verarbeitet downloads.bytes nicht korrekt.'
    }
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
DELETE FROM project_downloads WHERE project_id=$projectId AND media_id=$([int]$hf50ReuseMedia[0].id);
DELETE FROM downloads WHERE media_id=$([int]$hf50ReuseMedia[0].id);
DELETE FROM media WHERE id=$([int]$hf50ReuseMedia[0].id);
"@|Out-Null


    # HF60 runtime regression: bulk reuse must remove already completed media
    # from the worker queue while leaving a truly new medium pending. The SHA1
    # source deliberately keeps media.sha1 NULL and uses downloads.verified_sha1,
    # because media.sha1 is a unique identity in the production schema.
    $hf57BulkNow=Get-FsUtcNowText
    $hf57DirectTitle='File:HF60 bulk direct.jpg'
    $hf57SourceTitle='File:HF60 bulk hash source.jpg'
    $hf57TargetTitle='File:HF60 bulk hash target.jpg'
    $hf57NewTitle='File:HF60 bulk truly new.jpg'
    $hf57DirectSha='57aa000000000000000000000000000000000001'
    $hf57SharedSha='57bb000000000000000000000000000000000002'
    $hf57NewSha='57cc000000000000000000000000000000000003'
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
BEGIN IMMEDIATE;
INSERT INTO media(title,normalized_title,canonical_title,sha1,url,media_type,created_at,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $hf57DirectTitle),$(ConvertTo-FsSqlLiteral $hf57DirectTitle),$(ConvertTo-FsSqlLiteral $hf57DirectTitle),$(ConvertTo-FsSqlLiteral $hf57DirectSha),'https://example.invalid/hf57-direct.jpg','BITMAP',$(ConvertTo-FsSqlLiteral $hf57BulkNow),$(ConvertTo-FsSqlLiteral $hf57BulkNow));
INSERT INTO downloads(media_id,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,created_at,updated_at)
VALUES(last_insert_rowid(),'done','E:\Temp\hf57-direct.jpg',111,$(ConvertTo-FsSqlLiteral $hf57DirectSha),1,$projectId,$(ConvertTo-FsSqlLiteral $hf57BulkNow),$(ConvertTo-FsSqlLiteral $hf57BulkNow));
INSERT INTO project_downloads(project_id,media_id,status,updated_at)
SELECT $projectId,id,'pending',$(ConvertTo-FsSqlLiteral $hf57BulkNow) FROM media WHERE title=$(ConvertTo-FsSqlLiteral $hf57DirectTitle);

INSERT INTO media(title,normalized_title,canonical_title,url,media_type,created_at,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $hf57SourceTitle),$(ConvertTo-FsSqlLiteral $hf57SourceTitle),$(ConvertTo-FsSqlLiteral $hf57SourceTitle),'https://example.invalid/hf57-source.jpg','BITMAP',$(ConvertTo-FsSqlLiteral $hf57BulkNow),$(ConvertTo-FsSqlLiteral $hf57BulkNow));
INSERT INTO downloads(media_id,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,created_at,updated_at)
VALUES(last_insert_rowid(),'historical','E:\Temp\hf57-source.jpg',222,$(ConvertTo-FsSqlLiteral $hf57SharedSha),1,$projectId,$(ConvertTo-FsSqlLiteral $hf57BulkNow),$(ConvertTo-FsSqlLiteral $hf57BulkNow));

INSERT INTO media(title,normalized_title,canonical_title,sha1,url,media_type,created_at,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $hf57TargetTitle),$(ConvertTo-FsSqlLiteral $hf57TargetTitle),$(ConvertTo-FsSqlLiteral $hf57TargetTitle),$(ConvertTo-FsSqlLiteral $hf57SharedSha),'https://example.invalid/hf57-target.jpg','BITMAP',$(ConvertTo-FsSqlLiteral $hf57BulkNow),$(ConvertTo-FsSqlLiteral $hf57BulkNow));
INSERT INTO project_downloads(project_id,media_id,status,updated_at)
VALUES($projectId,last_insert_rowid(),'pending',$(ConvertTo-FsSqlLiteral $hf57BulkNow));

INSERT INTO media(title,normalized_title,canonical_title,sha1,url,media_type,created_at,updated_at)
VALUES($(ConvertTo-FsSqlLiteral $hf57NewTitle),$(ConvertTo-FsSqlLiteral $hf57NewTitle),$(ConvertTo-FsSqlLiteral $hf57NewTitle),$(ConvertTo-FsSqlLiteral $hf57NewSha),'https://example.invalid/hf57-new.jpg','BITMAP',$(ConvertTo-FsSqlLiteral $hf57BulkNow),$(ConvertTo-FsSqlLiteral $hf57BulkNow));
INSERT INTO project_downloads(project_id,media_id,status,updated_at)
VALUES($projectId,last_insert_rowid(),'pending',$(ConvertTo-FsSqlLiteral $hf57BulkNow));
COMMIT;
"@|Out-Null
    $hf57BulkResult=Invoke-FsDownloadReuseFastPath -ProjectId $projectId -Config $config -SqlitePath $sqlite -DatabasePath $db
    $hf57BulkRows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql @"
SELECT m.title,pd.status,d.status global_status,d.bytes
FROM media m
JOIN project_downloads pd ON pd.media_id=m.id AND pd.project_id=$projectId
LEFT JOIN downloads d ON d.media_id=m.id
WHERE m.title IN (
 $(ConvertTo-FsSqlLiteral $hf57DirectTitle),
 $(ConvertTo-FsSqlLiteral $hf57TargetTitle),
 $(ConvertTo-FsSqlLiteral $hf57NewTitle)
)
ORDER BY m.title;
"@)
    $hf57DirectState=(@($hf57BulkRows|Where-Object{$_.title -eq $hf57DirectTitle}))[0]
    $hf57TargetState=(@($hf57BulkRows|Where-Object{$_.title -eq $hf57TargetTitle}))[0]
    $hf57NewState=(@($hf57BulkRows|Where-Object{$_.title -eq $hf57NewTitle}))[0]
    if([int]$hf57BulkResult.Reused -lt 2 -or
       [string]$hf57DirectState.status -ne 'reused' -or
       [string]$hf57TargetState.status -ne 'reused' -or
       [string]$hf57TargetState.global_status -ne 'historical' -or
       [long]$hf57TargetState.bytes -ne 222 -or
       [string]$hf57NewState.status -ne 'pending'){
        throw 'HF60-Bulk-Reuse verarbeitet direkte/SHA1-Treffer oder echte Downloadaufgaben nicht korrekt.'
    }
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
DELETE FROM project_downloads WHERE project_id=$projectId AND media_id IN (SELECT id FROM media WHERE title IN (
 $(ConvertTo-FsSqlLiteral $hf57DirectTitle),$(ConvertTo-FsSqlLiteral $hf57TargetTitle),$(ConvertTo-FsSqlLiteral $hf57NewTitle)
));
DELETE FROM downloads WHERE media_id IN (SELECT id FROM media WHERE title IN (
 $(ConvertTo-FsSqlLiteral $hf57DirectTitle),$(ConvertTo-FsSqlLiteral $hf57SourceTitle),$(ConvertTo-FsSqlLiteral $hf57TargetTitle)
));
DELETE FROM media WHERE title IN (
 $(ConvertTo-FsSqlLiteral $hf57DirectTitle),$(ConvertTo-FsSqlLiteral $hf57SourceTitle),$(ConvertTo-FsSqlLiteral $hf57TargetTitle),$(ConvertTo-FsSqlLiteral $hf57NewTitle)
);
"@|Out-Null

    $tuneSamples=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT sample_type FROM download_tuning_samples WHERE project_id=$projectId ORDER BY id;")
    if(@($tuneSamples).Count -lt 4 -or -not(@($tuneSamples.sample_type) -contains 'recovery')){throw 'Live-, Fenster-, Recovery- und 429-Verlauf wurden nicht gespeichert.'}

    # Execute the actual HF60 monitor parser and chart-point code in a separate
    # STA PowerShell process. This catches Windows PowerShell 5.1 Object[] /
    # DataPoint conversion regressions before a drop-in is allowed to resume.
    $monitorShell=$null
    try{$monitorShell=(Get-Process -Id $PID -ErrorAction Stop).Path}catch{}
    if([string]::IsNullOrWhiteSpace($monitorShell)){$monitorShell='powershell.exe'}
    $monitorArgs=@(
        '-NoLogo','-NoProfile','-Sta','-ExecutionPolicy','Bypass',
        '-File',('"'+$monitorPath30+'"'),
        '-Project','"Self Test"',
        '-Workspace',('"'+$init.Paths.Root+'"'),
        '-SqlitePath',('"'+$sqlite+'"'),
        '-SelfTest'
    )
    $monitorTestProcess=Start-Process -FilePath $monitorShell -ArgumentList $monitorArgs -WindowStyle Hidden -Wait -PassThru
    if($monitorTestProcess.ExitCode -ne 0){throw "HF60-Monitor-Selbsttest fehlgeschlagen; ExitCode $($monitorTestProcess.ExitCode)."}

    Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $tuneRun -Status 'completed'
    Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $carryRun -Status 'completed' 

    # Task claim, Eigentümerschutz und Named Lock.
    Seed-FsCategoryTasks -ProjectId $projectId -Categories @('Category:Dentistry') -SqlitePath $sqlite -DatabasePath $db
    $first=@(Claim-FsTask -Table 'project_categories' -KeyColumn 'category_id' -ProjectId $projectId -Worker 'test-a' -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 30 -Limit 1)
    $second=@(Claim-FsTask -Table 'project_categories' -KeyColumn 'category_id' -ProjectId $projectId -Worker 'test-b' -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 30 -Limit 1)
    if($first.Count -ne 1 -or $second.Count -ne 0){throw 'Atomarer Task-Claim ist fehlgeschlagen.'}
    if(Complete-FsTask -Table 'project_categories' -Where "project_id=$projectId AND category_id=$([int]$first[0].category_id)" -Status 'done' -SqlitePath $sqlite -DatabasePath $db -Worker 'wrong-owner'){throw 'Falscher Worker konnte fremde Task abschließen.'}
    if(-not(Complete-FsTask -Table 'project_categories' -Where "project_id=$projectId AND category_id=$([int]$first[0].category_id)" -Status 'done' -SqlitePath $sqlite -DatabasePath $db -Worker 'test-a')){throw 'Richtiger Worker konnte Task nicht abschließen.'}

    # HF60: four download tasks are reserved in one transaction, including
    # their global downloads rows. Completing a file updates both tables in
    # one second transaction.
    $downloadBatchRun=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode 'Download' -Profile 'Fast' -ParametersJson '{}'
    $downloadBatchNow=Get-FsUtcNowText
    $downloadBatchSql=New-Object Text.StringBuilder
    for($batchIndex=1;$batchIndex -le 6;$batchIndex++){
        $title="File:HF60 batch $batchIndex.jpg"
        $normalized="hf44 batch $batchIndex.jpg"
        [void]$downloadBatchSql.AppendLine("INSERT INTO media(title,normalized_title,canonical_title,url,mime,media_type,created_at,updated_at) VALUES($(ConvertTo-FsSqlLiteral $title),$(ConvertTo-FsSqlLiteral $normalized),$(ConvertTo-FsSqlLiteral $title),'https://example.invalid/hf44-$batchIndex.jpg','image/jpeg','BITMAP',$(ConvertTo-FsSqlLiteral $downloadBatchNow),$(ConvertTo-FsSqlLiteral $downloadBatchNow));")
        [void]$downloadBatchSql.AppendLine("INSERT INTO project_downloads(project_id,media_id,status,updated_at) VALUES($projectId,last_insert_rowid(),'pending',$(ConvertTo-FsSqlLiteral $downloadBatchNow));")
    }
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql ("BEGIN IMMEDIATE;`n"+$downloadBatchSql.ToString()+"`nCOMMIT;")|Out-Null

    # Execute the same queue wrapper used by each real download worker. Under
    # StrictMode this catches an uninitialized module-scope queue immediately.
    $queueClaim=@(Get-FsNextDownloadTask -ProjectId $projectId -RunId $downloadBatchRun -Worker 'hf44-queue-worker' -Config $config -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 300)
    if($queueClaim.Count -ne 1){throw "HF60 Worker-Claim-Queue lieferte $($queueClaim.Count) statt einer Aufgabe."}
    Reset-FsWorkerTasks -ProjectId $projectId -Worker 'hf44-queue-worker' -SqlitePath $sqlite -DatabasePath $db -Reason 'HF60 Queue-Selbsttest beendet'

    $claimedDownloadBatch=@(Claim-FsDownloadTasks -ProjectId $projectId -RunId $downloadBatchRun -Worker 'hf44-batch-worker' -Config $config -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 300 -Limit 4)
    if($claimedDownloadBatch.Count -ne 4){throw "HF60 blockweiser Download-Claim lieferte $($claimedDownloadBatch.Count) statt 4 Tasks."}
    $batchClaimCounts=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT (SELECT COUNT(*) FROM project_downloads WHERE project_id=$projectId AND lease_owner='hf44-batch-worker' AND status='running') project_running,(SELECT COUNT(*) FROM downloads WHERE lease_owner='hf44-batch-worker' AND status='running') global_running;")
    if([int]$batchClaimCounts[0].project_running -ne 4 -or [int]$batchClaimCounts[0].global_running -ne 4){
        throw 'HF60 blockweiser Claim reserviert Projekt- und Globaltask nicht gemeinsam.'
    }
    $otherWorkerClaims=@(Claim-FsDownloadTasks -ProjectId $projectId -RunId $downloadBatchRun -Worker 'hf44-parallel-worker' -Config $config -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 300 -Limit 4)
    $firstIds=@($claimedDownloadBatch | ForEach-Object {[int]$_.media_id})
    $secondIds=@($otherWorkerClaims | ForEach-Object {[int]$_.media_id})
    $duplicateIds=@($firstIds | Where-Object {$secondIds -contains $_})
    if($duplicateIds.Count -ne 0){throw ("HF60 hat dieselbe media_id parallel an zwei Worker vergeben: {0}" -f ($duplicateIds -join ','))}
    $duplicateLeaseRows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT pd.media_id FROM project_downloads pd JOIN downloads d ON d.media_id=pd.media_id WHERE pd.project_id=$projectId AND pd.status='running' AND d.status='running' AND pd.lease_owner<>d.lease_owner;")
    if($duplicateLeaseRows.Count -ne 0){throw 'HF60 hat widersprüchliche Projekt-/Global-Lease-Owner erzeugt.'}
    $completedBatchMedia=[int]$claimedDownloadBatch[0].media_id
    [void](Complete-FsDownloadWorkItem -ProjectId $projectId -MediaId $completedBatchMedia -Worker 'hf44-batch-worker' -ProjectStatus 'done' -DownloadStatus 'done' -SqlitePath $sqlite -DatabasePath $db -LocalPath 'E:\Temp\hf44-selftest.jpg' -Bytes 123 -VerifiedSha1 $null -HistoricalComplete 1)
    $batchCompletion=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT (SELECT status FROM project_downloads WHERE project_id=$projectId AND media_id=$completedBatchMedia) project_status,(SELECT status FROM downloads WHERE media_id=$completedBatchMedia) global_status;")
    if([string]$batchCompletion[0].project_status -ne 'done' -or [string]$batchCompletion[0].global_status -ne 'done'){
        throw 'HF60 atomarer Downloadabschluss aktualisiert die beiden Statuszeilen nicht gemeinsam.'
    }
    Reset-FsWorkerTasks -ProjectId $projectId -Worker 'hf44-batch-worker' -SqlitePath $sqlite -DatabasePath $db -Reason 'HF60 Selbsttest beendet'
    Reset-FsWorkerTasks -ProjectId $projectId -Worker 'hf44-parallel-worker' -SqlitePath $sqlite -DatabasePath $db -Reason 'HF60 Parallel-Claim-Selbsttest beendet'

    # HF65: successful results are committed in small worker-local batches.
    # Four completed files must become visible together after one flush.
    $config.Download.CompletionBatchSize=4
    $hf65CompletionClaims=@(Claim-FsDownloadTasks -ProjectId $projectId -RunId $downloadBatchRun -Worker 'hf65-complete-worker' -Config $config -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 300 -Limit 4)
    if($hf65CompletionClaims.Count -ne 4){throw 'HF65 Ergebnis-Batch konnte nicht vier Downloadtasks claimen.'}
    foreach($hf65CompletionTask in $hf65CompletionClaims){
        [void](Submit-FsDownloadWorkItem -ProjectId $projectId -MediaId ([int]$hf65CompletionTask.media_id) -Worker 'hf65-complete-worker' -Config $config -ProjectStatus 'done' -DownloadStatus 'done' -SqlitePath $sqlite -DatabasePath $db -LocalPath ('E:\Temp\hf65-batch-'+[string]$hf65CompletionTask.media_id+'.jpg') -Bytes 321 -HistoricalComplete 1)
    }
    $hf65CompletionVisible=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT COUNT(*) count FROM project_downloads WHERE project_id=$projectId AND lease_owner IS NULL AND status='done' AND media_id IN ($((@($hf65CompletionClaims|ForEach-Object{[int]$_.media_id})) -join ','));")
    if($hf65CompletionVisible.Count -ne 1 -or [int]$hf65CompletionVisible[0].count -ne 4){throw 'HF65 Ergebnis-Batch hat vier erfolgreiche Dateien nicht gemeinsam persistiert.'}
    Reset-FsWorkerTasks -ProjectId $projectId -Worker 'hf65-complete-worker' -SqlitePath $sqlite -DatabasePath $db -Reason 'HF65 Ergebnis-Batch-Selbsttest beendet'

    Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $downloadBatchRun -Status 'completed'
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
DELETE FROM project_downloads WHERE media_id IN (SELECT id FROM media WHERE normalized_title LIKE 'hf44 batch %.jpg');
DELETE FROM downloads WHERE media_id IN (SELECT id FROM media WHERE normalized_title LIKE 'hf44 batch %.jpg');
DELETE FROM media WHERE normalized_title LIKE 'hf44 batch %.jpg';
"@|Out-Null

    # Retryfähige Fehler müssen offen bleiben, bis MaxAttempts erreicht ist.
    Seed-FsCategoryTasks -ProjectId $projectId -Categories @('Category:Retry test') -SqlitePath $sqlite -DatabasePath $db
    $retryTask=@(Claim-FsTask -Table 'project_categories' -KeyColumn 'category_id' -ProjectId $projectId -Worker 'retry-test' -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 30 -Limit 1 -MaxAttempts 4)
    if($retryTask.Count -ne 1){throw 'Retry-Testtask konnte nicht beansprucht werden.'}
    [void](Complete-FsTask -Table 'project_categories' -Where "project_id=$projectId AND category_id=$([int]$retryTask[0].category_id)" -Status 'failed' -SqlitePath $sqlite -DatabasePath $db -Worker 'retry-test' -Error 'selftest transient')
    $retryCounts=Get-FsStageCounts -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Stage 'category' -MaxAttempts 4
    if([int]$retryCounts.retryable -ne 1 -or [int]$retryCounts.failed -ne 0){throw 'Retryfähiger Fehler wurde fälschlich als endgültig gezählt.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "UPDATE project_categories SET attempts=4 WHERE project_id=$projectId AND category_id=$([int]$retryTask[0].category_id);"|Out-Null
    $finalCounts=Get-FsStageCounts -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Stage 'category' -MaxAttempts 4
    if([int]$finalCounts.retryable -ne 0 -or [int]$finalCounts.failed -ne 1){throw 'Endgültiger Fehler wurde nicht korrekt erkannt.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "DELETE FROM project_categories WHERE project_id=$projectId AND category_id=$([int]$retryTask[0].category_id);"|Out-Null

    # Hotfix 10: Run-Prüfung gehört in den atomaren Claim und Heartbeats dürfen
    # eine frisch beanspruchte Task nicht sofort mehrfach erneuern.
    $heartbeatRun=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode 'Status' -Profile 'Fast' -ParametersJson '{}'
    $heartbeatNow=Get-FsUtcNowText
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
INSERT INTO search_tasks(project_id,task_type,query_key,query_text,language,score,max_results,status,created_at,updated_at)
VALUES($projectId,'selftest','heartbeat-active','heartbeat-active','de',50,1,'pending',$(ConvertTo-FsSqlLiteral $heartbeatNow),$(ConvertTo-FsSqlLiteral $heartbeatNow));
INSERT INTO search_tasks(project_id,task_type,query_key,query_text,language,score,max_results,status,created_at,updated_at)
VALUES($projectId,'selftest','heartbeat-inactive','heartbeat-inactive','de',50,1,'pending',$(ConvertTo-FsSqlLiteral $heartbeatNow),$(ConvertTo-FsSqlLiteral $heartbeatNow));
"@|Out-Null
    $heartbeatTask=@(Claim-FsTask -Table 'search_tasks' -KeyColumn 'id' -ProjectId $projectId -Worker 'heartbeat-test' -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 3600 -Limit 1 -MaxAttempts 4 -RunId $heartbeatRun)
    if($heartbeatTask.Count -ne 1){throw 'Run-gebundener Task-Claim ist fehlgeschlagen.'}
    $leaseBefore=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT lease_until FROM search_tasks WHERE id=$([int]$heartbeatTask[0].id);")
    $heartbeat=New-FsWorkerHeartbeat -ProjectId $projectId -RunId $heartbeatRun -Stage 'query' -Worker 'heartbeat-test' -LeaseSeconds 3600 -SqlitePath $sqlite -DatabasePath $db -MinimumSeconds 60
    & $heartbeat
    & $heartbeat
    $leaseAfter=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT lease_until FROM search_tasks WHERE id=$([int]$heartbeatTask[0].id);")
    if([string]$leaseBefore[0].lease_until -ne [string]$leaseAfter[0].lease_until){throw 'Gedrosselter Heartbeat erneuerte eine frische Lease unnötig.'}
    Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $heartbeatRun -Status 'failed' -Error 'selftest inactive'
    if((Renew-FsWorkerTasks -ProjectId $projectId -RunId $heartbeatRun -Stage 'query' -Worker 'heartbeat-test' -LeaseSeconds 3600 -SqlitePath $sqlite -DatabasePath $db) -ne 0){throw 'Heartbeat erneuerte eine Lease für einen inaktiven Run.'}
    $inactiveClaim=@(Claim-FsTask -Table 'search_tasks' -KeyColumn 'id' -ProjectId $projectId -Worker 'inactive-claim' -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 3600 -Limit 1 -MaxAttempts 4 -RunId $heartbeatRun)
    if($inactiveClaim.Count -ne 0){throw 'Inaktiver Run konnte weiterhin Tasks beanspruchen.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "DELETE FROM search_tasks WHERE project_id=$projectId AND query_key IN ('heartbeat-active','heartbeat-inactive');"|Out-Null

    # Leere Statementlisten sind ein gueltiger No-op und duerfen nicht bereits bei der Parameterbindung scheitern.
    Invoke-FsSqlBatch -SqlitePath $sqlite -DatabasePath $db -Statements @() -Immediate

    # Der laufende Lease-Reaper darf nur die aktive Stufe prüfen. Eine
    # Query-Prüfung darf keinen abgelaufenen Kategorie-Task anfassen und dadurch
    # unnötig den gemeinsamen Schreibslot belegen.
    Seed-FsCategoryTasks -ProjectId $projectId -Categories @('Category:Reaper isolation') -SqlitePath $sqlite -DatabasePath $db
    $reaperCategory=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT category_id FROM project_categories pc JOIN categories c ON c.id=pc.category_id WHERE pc.project_id=$projectId AND c.title='Category:Reaper isolation';")
    $expired=(Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "UPDATE project_categories SET status='running',lease_owner='reaper-test',lease_until=$(ConvertTo-FsSqlLiteral $expired) WHERE project_id=$projectId AND category_id=$([int]$reaperCategory[0].category_id);"|Out-Null
    [void](Reset-FsExpiredTasks -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db -Stage 'query')
    $stillRunning=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT status FROM project_categories WHERE project_id=$projectId AND category_id=$([int]$reaperCategory[0].category_id);")
    if([string]$stillRunning[0].status -ne 'running'){throw 'Query-Reaper hat eine fremde Kategorie-Stufe verändert.'}
    [void](Reset-FsExpiredTasks -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db -Stage 'category')
    $resetState=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT status FROM project_categories WHERE project_id=$projectId AND category_id=$([int]$reaperCategory[0].category_id);")
    if([string]$resetState[0].status -ne 'pending'){throw 'Kategorie-Reaper hat abgelaufene Lease nicht zurückgesetzt.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "DELETE FROM project_categories WHERE project_id=$projectId AND category_id=$([int]$reaperCategory[0].category_id);"|Out-Null

    # Skalierter Query-Bulk-Test: Die Produktionsdatenbank enthält rund
    # 58.000 Medien. Der Test erzeugt dieselbe Größenordnung und mischt 160
    # vorhandene mit 160 neuen Page-IDs. Der indexierte Hotfix-10-Pfad muss
    # deutlich unter dem SQLite-Zeitlimit bleiben und idempotent sein.
    $scaleWorkspace=Join-Path $env:TEMP ('FindSeriesV5-ScaleTest-'+[Guid]::NewGuid().ToString('N'))
    try {
        $scaleInit=Initialize-FsDatabase -Workspace $scaleWorkspace -SqlitePath $sqlite
        $scaleSqlite=$scaleInit.SqlitePath;$scaleDb=$scaleInit.Paths.Database
        $scaleConfig=Get-FsProjectConfig -Profile 'Fast' -ProfilesPath (Join-Path $PSScriptRoot 'Config\profiles.json')
        $scaleProject=Save-FsProject -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Name 'Self Test Scale' -Slug 'self-test-scale' -Profile 'Fast' -Language 'de' -ConfigJson ($scaleConfig|ConvertTo-Json -Depth 20 -Compress)
        $scaleProjectId=[int]$scaleProject.id
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -ExecutionTimeoutMs 120000 -BusyRetries 0 -Sql @"
WITH RECURSIVE cnt(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM cnt WHERE x<60000)
INSERT INTO media(page_id,title,normalized_title,canonical_title,metadata_level,metadata_checked_level,created_at,updated_at)
SELECT x,'File:Scale background '||x||'.jpg','file:scale background '||x||'.jpg','File:Scale background '||x||'.jpg',0,0,datetime('now'),datetime('now') FROM cnt;
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'pageid',CAST(page_id AS TEXT),id,'selftest',datetime('now'),datetime('now') FROM media WHERE page_id BETWEEN 1 AND 60000;
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'title',normalized_title,id,'selftest',datetime('now'),datetime('now') FROM media WHERE page_id BETWEEN 1 AND 60000;
INSERT INTO project_media(project_id,media_id,score,best_source,selected,first_seen_at,updated_at)
SELECT $scaleProjectId,id,50,'selftest-scale',1,datetime('now'),datetime('now') FROM media WHERE page_id BETWEEN 1 AND 58000
ON CONFLICT(project_id,media_id) DO NOTHING;
"@ | Out-Null
    $bulkItems=New-Object Collections.Generic.List[object]
    foreach($n in 1..160){$bulkItems.Add([pscustomobject]@{pageid=$n;title=("File:Scale background {0}.jpg" -f $n)})}
    foreach($n in 1..160){$bulkItems.Add([pscustomobject]@{pageid=(9000000+$n);title=("File:Hotfix10 bulk {0}.jpg" -f $n)})}
    $bulkWatch=[Diagnostics.Stopwatch]::StartNew()
    $bulkWritten=Invoke-FsQueryResultBulkWrite -ProjectId $scaleProjectId -Items $bulkItems.ToArray() -TaskType 'selftest-query' -QueryText 'hotfix10-bulk' -Language 'de' -Score 72 -SqlitePath $scaleSqlite -DatabasePath $scaleDb
    if($bulkWatch.Elapsed.TotalSeconds -gt 60){throw "Skalierter Query-Bulk benötigte $([Math]::Round($bulkWatch.Elapsed.TotalSeconds,1)) s und ist weiterhin zu langsam."}
    if([int]$bulkWritten.Written -ne 320){throw "Query-Bulk-Upsert meldete $($bulkWritten.Written) statt 320 Treffer."}
    $noOpSentinel='2001-01-01T00:00:00.0000000Z'
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql "UPDATE project_media SET updated_at=$(ConvertTo-FsSqlLiteral $noOpSentinel) WHERE project_id=$scaleProjectId AND media_id=(SELECT id FROM media WHERE page_id=1 LIMIT 1);"|Out-Null
    $bulkWrittenAgain=Invoke-FsQueryResultBulkWrite -ProjectId $scaleProjectId -Items $bulkItems.ToArray() -TaskType 'selftest-query' -QueryText 'hotfix10-bulk' -Language 'de' -Score 72 -SqlitePath $scaleSqlite -DatabasePath $scaleDb
    $noOpRow=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT updated_at FROM project_media WHERE project_id=$scaleProjectId AND media_id=(SELECT id FROM media WHERE page_id=1 LIMIT 1);")
    if([string]$noOpRow[0].updated_at -ne $noOpSentinel){throw 'Unveränderte Projektzuordnung wurde beim zweiten Bulk unnötig aktualisiert.'}
    $bulkCounts=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM media WHERE page_id BETWEEN 9000001 AND 9000160) new_media_count,
 (SELECT COUNT(*) FROM project_media pm JOIN media m ON m.id=pm.media_id WHERE pm.project_id=$scaleProjectId AND (m.page_id BETWEEN 1 AND 160 OR m.page_id BETWEEN 9000001 AND 9000160)) project_count,
 (SELECT COUNT(*) FROM discoveries WHERE project_id=$scaleProjectId AND query_text='hotfix10-bulk') discovery_count;
"@)
    if([int]$bulkWrittenAgain.Written -ne 320 -or [int]$bulkCounts[0].new_media_count -ne 160 -or [int]$bulkCounts[0].project_count -ne 320 -or [int]$bulkCounts[0].discovery_count -ne 320){throw 'Skalierter Query-Bulk-Upsert ist nicht vollständig oder nicht idempotent.'}


    # Hotfix 14: Das Metadaten-Seeding darf bei einem Projektbestand in
    # Produktionsgröße nicht mehr als monolithische 180-Sekunden-Transaktion
    # laufen. Alle Kandidaten werden keyset-basiert in 2.000er-Batches
    # vorbereitet; ein zweiter Lauf muss idempotent bleiben.
    $metadataSeedWatch=[Diagnostics.Stopwatch]::StartNew()
    $metadataSeed=Seed-FsMetadataTasks -ProjectId $scaleProjectId -Level 2 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -SeedBatchSize 2000
    if($metadataSeedWatch.Elapsed.TotalSeconds -gt 90){throw "Skaliertes Metadaten-Seeding benötigte $([Math]::Round($metadataSeedWatch.Elapsed.TotalSeconds,1)) s und ist weiterhin zu langsam."}
    $metadataSeedCounts=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM project_media pm JOIN media m ON m.id=pm.media_id WHERE pm.project_id=$scaleProjectId AND COALESCE(m.metadata_checked_level,0)<2) candidate_count,
 (SELECT COUNT(*) FROM metadata_tasks WHERE project_id=$scaleProjectId AND required_level>=2 AND status='pending') task_count;
"@)
    if([int]$metadataSeed.Candidates -ne [int]$metadataSeedCounts[0].candidate_count -or [int]$metadataSeedCounts[0].task_count -ne [int]$metadataSeedCounts[0].candidate_count){throw 'Batchweises Metadaten-Seeding ist unvollständig.'}
    $metadataNoOpSentinel='2002-02-02T00:00:00.0000000Z'
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql "UPDATE metadata_tasks SET updated_at=$(ConvertTo-FsSqlLiteral $metadataNoOpSentinel) WHERE project_id=$scaleProjectId AND media_id=(SELECT id FROM media WHERE page_id=1 LIMIT 1);"|Out-Null
    $metadataSeedAgain=Seed-FsMetadataTasks -ProjectId $scaleProjectId -Level 2 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -SeedBatchSize 2000
    $metadataNoOpRow=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT updated_at FROM metadata_tasks WHERE project_id=$scaleProjectId AND media_id=(SELECT id FROM media WHERE page_id=1 LIMIT 1);")
    if([string]$metadataNoOpRow[0].updated_at -ne $metadataNoOpSentinel -or [int]$metadataSeedAgain.Changed -ne 0){throw 'Bereits korrekt vorbereitete Metadaten-Tasks wurden beim zweiten Seed unnötig aktualisiert.'}

    # HF60 production regression: a large project with only 444 missing task
    # rows must inspect and write only that coverage delta. HF51 joined the
    # complete project inventory to media first and then tried to write all
    # 444 rows in one 60-second transaction.
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql @"
DELETE FROM metadata_tasks
WHERE project_id=$scaleProjectId
  AND media_id IN (SELECT id FROM media WHERE page_id BETWEEN 1001 AND 1444);
"@|Out-Null
    $metadataDeltaWatch=[Diagnostics.Stopwatch]::StartNew()
    $metadataDeltaSeed=Seed-FsMetadataTasks -ProjectId $scaleProjectId -Level 2 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -SeedBatchSize 2000
    $metadataDeltaRows=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT COUNT(*) count FROM metadata_tasks WHERE project_id=$scaleProjectId AND media_id IN (SELECT id FROM media WHERE page_id BETWEEN 1001 AND 1444) AND required_level>=2;")
    if($metadataDeltaWatch.Elapsed.TotalSeconds -gt 60 -or
       [int]$metadataDeltaSeed.Scanned -ne 444 -or
       [int]$metadataDeltaSeed.Candidates -ne 444 -or
       [int]$metadataDeltaSeed.Changed -ne 444 -or
       [int]$metadataDeltaRows[0].count -ne 444){
        throw ("HF60-Abdeckungsdelta ist unvollständig oder fällt auf den Vollscan zurück: {0}s; Scanned={1}; Candidates={2}; Changed={3}; Tasks={4}." -f [Math]::Round($metadataDeltaWatch.Elapsed.TotalSeconds,2),$metadataDeltaSeed.Scanned,$metadataDeltaSeed.Candidates,$metadataDeltaSeed.Changed,$metadataDeltaRows[0].count)
    }

    $negativeCheckSentinel='2003-03-03T00:00:00.0000000Z'
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql @"
UPDATE media SET metadata_level=0,metadata_checked_level=2 WHERE page_id=2;
UPDATE metadata_tasks SET status='skipped',attempts=1,last_error='Commons lieferte keine Bildmetadaten',updated_at=$(ConvertTo-FsSqlLiteral $negativeCheckSentinel) WHERE project_id=$scaleProjectId AND media_id=(SELECT id FROM media WHERE page_id=2 LIMIT 1);
"@|Out-Null
    $negativeSeed=Seed-FsMetadataTasks -ProjectId $scaleProjectId -Level 2 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -SeedBatchSize 2000
    $negativeRow=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT status,updated_at FROM metadata_tasks WHERE project_id=$scaleProjectId AND media_id=(SELECT id FROM media WHERE page_id=2 LIMIT 1);")
    if([string]$negativeRow[0].status -ne 'skipped' -or [string]$negativeRow[0].updated_at -ne $negativeCheckSentinel){throw 'Erfolgreich negativ geprüfte Metadaten wurden beim Resume erneut eingereiht.'}

    # HF60: If task coverage is already complete, a sparse checked-level pattern
    # is irrelevant for seeding. The delta path must not rescan the 58k project
    # inventory merely because many media rows remain below the checked level.
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql "UPDATE media SET metadata_checked_level=CASE WHEN id%18=0 THEN 0 ELSE 2 END;"|Out-Null
    $sparseExpected=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT COUNT(*) media_count FROM project_media WHERE project_id=$scaleProjectId;")
    $sparseWatch=[Diagnostics.Stopwatch]::StartNew()
    $sparseSeed=Seed-FsMetadataTasks -ProjectId $scaleProjectId -Level 2 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -SeedBatchSize 2000
    if($sparseWatch.Elapsed.TotalSeconds -gt 15){throw "Vollständig abgedecktes Metadaten-Seeding benötigte $([Math]::Round($sparseWatch.Elapsed.TotalSeconds,1)) s und scannt weiterhin unnötig."}
    if([int]$sparseSeed.Scanned -ne 0 -or [int]$sparseSeed.Candidates -ne 0 -or [int]$sparseSeed.Changed -ne 0){throw 'HF60 scannt trotz vollständiger Taskabdeckung unnötig Projektmedien.'}

    # Hotfix 21: When all project tasks are final, Resume must return before
    # any project scan. If one historical task row is absent but the medium is
    # already checked, the fallback scan must remain read-only and complete.
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql @"
UPDATE media SET metadata_checked_level=2;
UPDATE metadata_tasks SET required_level=2,status='done',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL WHERE project_id=$scaleProjectId;
"@|Out-Null
    $completedSeedWatch=[Diagnostics.Stopwatch]::StartNew()
    $completedSeed=Seed-FsMetadataTasks -ProjectId $scaleProjectId -Level 2 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -SeedBatchSize 2000
    if($completedSeedWatch.Elapsed.TotalSeconds -gt 10 -or -not [bool]$completedSeed.FastPath -or [int]$completedSeed.Scanned -ne 0 -or [int]$completedSeed.Candidates -ne 0){
        throw ("Vollständig abgeschlossene Metadaten gingen nicht über den Fast-Path: {0}s; FastPath={1}; Scanned={2}; Candidates={3}." -f [Math]::Round($completedSeedWatch.Elapsed.TotalSeconds,2),$completedSeed.FastPath,$completedSeed.Scanned,$completedSeed.Candidates)
    }
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql "DELETE FROM metadata_tasks WHERE project_id=$scaleProjectId AND media_id=(SELECT MIN(media_id) FROM project_media WHERE project_id=$scaleProjectId);"|Out-Null
    $checkedWithoutTaskWatch=[Diagnostics.Stopwatch]::StartNew()
    $checkedWithoutTaskSeed=Seed-FsMetadataTasks -ProjectId $scaleProjectId -Level 2 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -SeedBatchSize 2000
    # Hotfix 28: Since Hotfix 25 the checked-level is the authoritative proof
    # that metadata work is complete. A missing historical task row may therefore
    # either take the completed Fast-Path (preferred) or the older read-only
    # fallback scan. Both are valid when they create no candidate and change no task.
    $checkedWithoutTaskSeconds=$checkedWithoutTaskWatch.Elapsed.TotalSeconds
    $checkedWithoutTaskCommonValid=([int]$checkedWithoutTaskSeed.Candidates -eq 0 -and [int]$checkedWithoutTaskSeed.Changed -eq 0)
    $checkedWithoutTaskFastValid=([bool]$checkedWithoutTaskSeed.FastPath -and [int]$checkedWithoutTaskSeed.Scanned -eq 0 -and $checkedWithoutTaskSeconds -le 10)
    $checkedWithoutTaskDeltaValid=(-not [bool]$checkedWithoutTaskSeed.FastPath -and [int]$checkedWithoutTaskSeed.Scanned -le 1 -and $checkedWithoutTaskSeconds -le 15)
    if(-not $checkedWithoutTaskCommonValid -or (-not $checkedWithoutTaskFastValid -and -not $checkedWithoutTaskDeltaValid)){
        throw ("Geprüftes Medium ohne historische Taskzeile wurde instabil behandelt: {0}s; FastPath={1}; Scanned={2}; Candidates={3}; Changed={4}." -f [Math]::Round($checkedWithoutTaskSeconds,2),$checkedWithoutTaskSeed.FastPath,$checkedWithoutTaskSeed.Scanned,$checkedWithoutTaskSeed.Candidates,$checkedWithoutTaskSeed.Changed)
    }

    # Hotfix 18: Neighbor-Seeds must not evaluate the rejection predicate and
    # ORDER BY over the complete 66k project in one 180-second statement.
    # Scan top-scored project_media in bounded keyset batches instead.
    $neighborNow=Get-FsUtcNowText
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql @"
UPDATE media SET metadata_level=2,metadata_checked_level=2,current_uploader='selftest-uploader' WHERE page_id BETWEEN 1 AND 1000;
UPDATE project_media SET score=100,selected=1 WHERE project_id=$scaleProjectId AND media_id IN (SELECT id FROM media WHERE page_id BETWEEN 1 AND 1000);
INSERT OR IGNORE INTO media_rejections(page_id,reason,source,rejected_at,updated_at) VALUES(1,'selftest','selftest',$(ConvertTo-FsSqlLiteral $neighborNow),$(ConvertTo-FsSqlLiteral $neighborNow));
"@|Out-Null
    $scaleConfig.Neighbors.MaxSeeds=100
    $scaleConfig.Neighbors.MinScore=40
    $scaleConfig.Neighbors.SeedBatchSize=500
    $neighborWatch=[Diagnostics.Stopwatch]::StartNew()
    $neighborSeed=Seed-FsNeighborTasks -ProjectId $scaleProjectId -Config $scaleConfig -SqlitePath $scaleSqlite -DatabasePath $scaleDb
    if($neighborWatch.Elapsed.TotalSeconds -gt 30){throw "Skaliertes Nachbar-Seeding benötigte $([Math]::Round($neighborWatch.Elapsed.TotalSeconds,1)) s und ist weiterhin zu langsam."}
    $neighborCount=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT COUNT(*) count FROM neighbor_tasks WHERE project_id=$scaleProjectId;")
    $rejectedNeighborCount=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT COUNT(*) count FROM neighbor_tasks nt JOIN media m ON m.id=nt.media_id WHERE nt.project_id=$scaleProjectId AND m.page_id=1;")
    if([int]$neighborCount[0].count -ne 100 -or [int]$rejectedNeighborCount[0].count -ne 0 -or [int]$neighborSeed.Inserted -ne 100){throw 'Batchweises Nachbar-Seeding ist unvollständig oder ignoriert globale Ablehnungen.'}
    $neighborSeedAgain=Seed-FsNeighborTasks -ProjectId $scaleProjectId -Config $scaleConfig -SqlitePath $scaleSqlite -DatabasePath $scaleDb
    if([int]$neighborSeedAgain.Inserted -ne 0){throw 'Bereits vorhandene Nachbar-Seeds wurden erneut angelegt.'}
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql "DELETE FROM media_rejections WHERE page_id=1 AND source='selftest';"|Out-Null

    # Hotfix 22: 100 Neighbor-Treffer werden auf dem bereits mit 60k Medien
    # gefüllten Workspace set-basiert geschrieben. Der zweite Lauf muss
    # idempotent sein und darf weder Medien noch Projektzuordnungen duplizieren.
    $neighborBulkItems=New-Object Collections.ArrayList
    foreach($n in 1..100){
        $sha=('{0:x40}' -f (8000000+$n))
        [void]$neighborBulkItems.Add([pscustomobject]@{
            title=("File:Neighbor bulk selftest {0}.jpg" -f $n)
            sha1=$sha
            url=("https://example.invalid/neighbor/{0}.jpg" -f $n)
            descriptionurl=("https://example.invalid/wiki/File:Neighbor_bulk_selftest_{0}.jpg" -f $n)
            mime='image/jpeg'
            mediatype='BITMAP'
            size=(1000+$n)
            width=100
            height=100
            user='selftest-uploader'
            timestamp='2026-08-03T00:00:00Z'
        })
    }
    $parentRow=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql "SELECT id,title FROM media WHERE page_id=2 LIMIT 1;")
    $neighborBulkWatch=[Diagnostics.Stopwatch]::StartNew()
    $neighborBulk=Invoke-FsNeighborResultBulkWrite -ProjectId $scaleProjectId -Items ([object[]]$neighborBulkItems.ToArray()) -SeedTitle ([string]$parentRow[0].title) -ParentMediaId ([int]$parentRow[0].id) -Uploader 'selftest-uploader' -Score 38 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -ChunkSize 100
    if($neighborBulkWatch.Elapsed.TotalSeconds -gt 30 -or [int]$neighborBulk.UniqueCount -ne 100 -or [int]$neighborBulk.Resolved -ne 100){
        throw ("Neighbor-Bulk ist zu langsam oder unvollständig: {0}s; Unique={1}; Resolved={2}." -f [Math]::Round($neighborBulkWatch.Elapsed.TotalSeconds,2),$neighborBulk.UniqueCount,$neighborBulk.Resolved)
    }
    $neighborBulkAgain=Invoke-FsNeighborResultBulkWrite -ProjectId $scaleProjectId -Items ([object[]]$neighborBulkItems.ToArray()) -SeedTitle ([string]$parentRow[0].title) -ParentMediaId ([int]$parentRow[0].id) -Uploader 'selftest-uploader' -Score 38 -SqlitePath $scaleSqlite -DatabasePath $scaleDb -ChunkSize 100
    $neighborBulkCounts=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM media WHERE title LIKE 'File:Neighbor bulk selftest %') media_count,
 (SELECT COUNT(*) FROM project_media pm JOIN media m ON m.id=pm.media_id WHERE pm.project_id=$scaleProjectId AND m.title LIKE 'File:Neighbor bulk selftest %') project_count,
 (SELECT COUNT(*) FROM discoveries d JOIN media m ON m.id=d.media_id WHERE d.project_id=$scaleProjectId AND d.source_type='neighbor' AND m.title LIKE 'File:Neighbor bulk selftest %') discovery_count;
"@)
    if([int]$neighborBulkAgain.Resolved -ne 100 -or [int]$neighborBulkCounts[0].media_count -ne 100 -or [int]$neighborBulkCounts[0].project_count -ne 100 -or [int]$neighborBulkCounts[0].discovery_count -ne 100){
        throw 'Neighbor-Bulk ist nicht vollständig oder nicht idempotent.'
    }

    # Derselbe Batch-Schutz gilt für die spätere Download-Vorbereitung.
    Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Sql "UPDATE media SET url='https://example.invalid/scale/'||page_id||'.jpg',mime='image/jpeg',media_type='BITMAP' WHERE page_id BETWEEN 1 AND 5000;"|Out-Null
    $scaleConfig.Download.SeedBatchSize=2000
    $downloadSeed=Seed-FsDownloadTasks -ProjectId $scaleProjectId -Config $scaleConfig -SqlitePath $scaleSqlite -DatabasePath $scaleDb
    $downloadSeedCounts=@(Invoke-FsSqlite -SqlitePath $scaleSqlite -DatabasePath $scaleDb -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM project_downloads pd JOIN media m ON m.id=pd.media_id WHERE pd.project_id=$scaleProjectId AND m.page_id BETWEEN 1 AND 5000) task_count,
 (SELECT COUNT(*) FROM project_media pm JOIN media m ON m.id=pm.media_id WHERE pm.project_id=$scaleProjectId AND m.page_id BETWEEN 1 AND 5000 AND pm.download_requested=1) requested_count;
"@)
    if([int]$downloadSeed.Processed -ne 5000 -or [int]$downloadSeedCounts[0].task_count -ne 5000 -or [int]$downloadSeedCounts[0].requested_count -ne 5000){throw 'Batchweises Download-Seeding ist unvollständig.'}
    $downloadSeedAgain=Seed-FsDownloadTasks -ProjectId $scaleProjectId -Config $scaleConfig -SqlitePath $scaleSqlite -DatabasePath $scaleDb
    if(-not [bool]$downloadSeedAgain.FastPath -or [int]$downloadSeedAgain.Scanned -ne 0 -or [int]$downloadSeedAgain.Processed -ne 0){throw 'Abgeschlossenes Download-Seeding scannt weiterhin den vollständigen Projektbestand.'}
    }
    finally {
        if(Test-Path -LiteralPath $scaleWorkspace){Remove-Item -LiteralPath $scaleWorkspace -Recurse -Force -ErrorAction SilentlyContinue}
    }

    # Hotfix 11: Explorer review export, delete-to-reject synchronization and
    # global exclusion across later query/download paths.
    $config.Review.Enabled=$true
    $config.Review.BatchSize=50
    $config.Review.MaxExportsPerSync=100
    $config.Review.LinkMode='Auto'
    $config.Review.RemoveOriginalOnReject=$true
    $reviewNow=Get-FsUtcNowText
    $reviewSha='cccccccccccccccccccccccccccccccccccccccc'
    $reviewTitle='File:Review "illegal" <name>|question?.jpg'
    $reviewNormalized='review "illegal" <name>|question?.jpg'
    $reviewMediaRoot=Join-Path $init.Paths.Media 'cc'
    New-Item -ItemType Directory -Path $reviewMediaRoot -Force|Out-Null
    $reviewSource=Join-Path $reviewMediaRoot 'Review selftest.jpg'
    [IO.File]::WriteAllBytes($reviewSource,[Text.Encoding]::UTF8.GetBytes('findseries-review-selftest'))
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
INSERT INTO media(page_id,title,normalized_title,canonical_title,sha1,url,mime,media_type,metadata_level,metadata_checked_level,created_at,updated_at)
VALUES(777777,$(ConvertTo-FsSqlLiteral $reviewTitle),$(ConvertTo-FsSqlLiteral $reviewNormalized),$(ConvertTo-FsSqlLiteral $reviewTitle),$(ConvertTo-FsSqlLiteral $reviewSha),'https://example.invalid/review-selftest.jpg','image/jpeg','BITMAP',2,2,$(ConvertTo-FsSqlLiteral $reviewNow),$(ConvertTo-FsSqlLiteral $reviewNow));
INSERT INTO project_media(project_id,media_id,score,best_source,selected,download_requested,first_seen_at,updated_at)
SELECT $projectId,id,88,'review-selftest',1,1,$(ConvertTo-FsSqlLiteral $reviewNow),$(ConvertTo-FsSqlLiteral $reviewNow) FROM media WHERE page_id=777777;
INSERT INTO downloads(media_id,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,created_at,updated_at)
SELECT id,'done',$(ConvertTo-FsSqlLiteral $reviewSource),25,$(ConvertTo-FsSqlLiteral $reviewSha),1,$projectId,$(ConvertTo-FsSqlLiteral $reviewNow),$(ConvertTo-FsSqlLiteral $reviewNow) FROM media WHERE page_id=777777;
INSERT INTO project_downloads(project_id,media_id,status,updated_at)
SELECT $projectId,id,'done',$(ConvertTo-FsSqlLiteral $reviewNow) FROM media WHERE page_id=777777;
"@|Out-Null
    try {
        $reviewExport=Sync-FsReview -ProjectId $projectId -Workspace $init.Paths.Root -Config $config -SqlitePath $sqlite -DatabasePath $db -MaxExports 100 -Quiet
    } catch {
        $detail=$_.Exception.Message
        if($_.ScriptStackTrace){$detail+="`nPowerShell-Stack:`n$($_.ScriptStackTrace)"}
        if($_.Exception.InnerException){$detail+="`nInnerException: $($_.Exception.InnerException.Message)"}
        throw "Review-Sync Selbsttest fehlgeschlagen: $detail"
    }
    if([int]$reviewExport.Exported -ne 1){throw "Review-Sync exportierte $($reviewExport.Exported) statt eines Bildes."}
    $reviewRows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT review_path,source_path,status FROM review_exports WHERE project_id=$projectId AND media_id=(SELECT id FROM media WHERE page_id=777777);")
    if($reviewRows.Count -ne 1 -or -not(Test-Path -LiteralPath ([string]$reviewRows[0].review_path) -PathType Leaf)){throw 'Review-Datei wurde nicht erzeugt.'}
    $reviewLeaf=[IO.Path]::GetFileName([string]$reviewRows[0].review_path)
    foreach($invalidChar in [IO.Path]::GetInvalidFileNameChars()){
        if($reviewLeaf.Contains([string]$invalidChar)){throw "Review-Dateiname enthält weiterhin ein ungültiges Zeichen: $invalidChar"}
    }
    if([IO.Path]::GetExtension($reviewLeaf) -ne '.jpg'){throw "Review-Dateiendung wurde nicht aus der realen Quelldatei erhalten: $reviewLeaf"}
    # Wird die komplette Review-Struktur versehentlich entfernt, dürfen die
    # vorhandenen Exporte nicht als Massenablehnung interpretiert werden.
    $reviewProjectRoot=[string]$reviewExport.Root
    Remove-Item -LiteralPath $reviewProjectRoot -Recurse -Force
    $reviewSafety=Sync-FsReview -ProjectId $projectId -Workspace $init.Paths.Root -Config $config -SqlitePath $sqlite -DatabasePath $db -MaxExports 0 -Quiet
    if([int]$reviewSafety.Rejected -ne 0 -or [int]$reviewSafety.RestoredReviewLinks -ne 1 -or -not(Test-Path -LiteralPath ([string]$reviewRows[0].review_path) -PathType Leaf)){throw 'Fehlende Review-Struktur wurde nicht sicher rekonstruiert.'}
    Remove-Item -LiteralPath ([string]$reviewRows[0].review_path) -Force
    $reviewReject=Sync-FsReview -ProjectId $projectId -Workspace $init.Paths.Root -Config $config -SqlitePath $sqlite -DatabasePath $db -MaxExports 0 -Quiet
    if([int]$reviewReject.Rejected -ne 1){throw 'Gelöschte Review-Datei wurde nicht als globale Ablehnung erkannt.'}
    if(Test-Path -LiteralPath $reviewSource -PathType Leaf){throw 'Zentrale Mediendatei blieb nach globaler Ablehnung bestehen.'}
    $reviewState=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM media_rejections WHERE media_id=(SELECT id FROM media WHERE page_id=777777) OR page_id=777777 OR sha1=$(ConvertTo-FsSqlLiteral $reviewSha) OR normalized_title=$(ConvertTo-FsSqlLiteral $reviewNormalized)) rejection_count,
 (SELECT selected FROM project_media WHERE project_id=$projectId AND media_id=(SELECT id FROM media WHERE page_id=777777)) selected,
 (SELECT status FROM downloads WHERE media_id=(SELECT id FROM media WHERE page_id=777777)) download_status,
 (SELECT status FROM project_downloads WHERE project_id=$projectId AND media_id=(SELECT id FROM media WHERE page_id=777777)) project_download_status;
"@)
    if([int]$reviewState[0].rejection_count -lt 3 -or [int]$reviewState[0].selected -ne 0 -or [string]$reviewState[0].download_status -ne 'rejected' -or [string]$reviewState[0].project_download_status -ne 'skipped'){throw 'Globale Ablehnung wurde nicht vollständig in Datenbank und Queues propagiert.'}
    $rejectedQuery=Invoke-FsQueryResultBulkWrite -ProjectId $projectId -Items @([pscustomobject]@{pageid=777777;title=$reviewTitle}) -TaskType 'selftest-query' -QueryText 'review-rejected-query' -Language 'de' -Score 99 -SqlitePath $sqlite -DatabasePath $db
    if([int]$rejectedQuery.NewProjectMedia -ne 0){throw 'Global abgelehntes Medium wurde von einer späteren Query erneut als neu gezählt.'}
    $rejectedDiscovery=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT COUNT(*) count FROM discoveries WHERE project_id=$projectId AND query_text='review-rejected-query';")
    if([int]$rejectedDiscovery[0].count -ne 0){throw 'Global abgelehntes Medium wurde über ein anderes Keyword erneut als Discovery gespeichert.'}
    Seed-FsDownloadTasks -ProjectId $projectId -Config $config -SqlitePath $sqlite -DatabasePath $db
    $rejectedDownload=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT status FROM project_downloads WHERE project_id=$projectId AND media_id=(SELECT id FROM media WHERE page_id=777777);")
    if([string]$rejectedDownload[0].status -ne 'skipped'){throw 'Download-Seeding reaktivierte ein global abgelehntes Medium.'}
    $reviewMediaRows=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT id FROM media WHERE page_id=777777;')
    $reviewMediaId=[int]$reviewMediaRows[0].id
    $restore=Restore-FsRejectedMedia -SqlitePath $sqlite -DatabasePath $db -MediaId $reviewMediaId
    if([int]$restore.RemovedRejections -lt 3 -or [int]$restore.ReactivatedMedia -ne 1){throw 'Wiederherstellung einer globalen Ablehnung ist fehlgeschlagen.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
DELETE FROM discoveries WHERE query_text='review-rejected-query';
DELETE FROM review_exports WHERE media_id IN (SELECT id FROM media WHERE page_id=777777);
DELETE FROM project_downloads WHERE media_id IN (SELECT id FROM media WHERE page_id=777777);
DELETE FROM downloads WHERE media_id IN (SELECT id FROM media WHERE page_id=777777);
DELETE FROM project_media WHERE media_id IN (SELECT id FROM media WHERE page_id=777777);
DELETE FROM media_identities WHERE media_id IN (SELECT id FROM media WHERE page_id=777777);
DELETE FROM media WHERE page_id=777777;
"@|Out-Null

    # Ein großer SQL-Batch darf die Lease nicht vor jedem Teilstück erneuern.
    # Bei schnellem Durchlauf und 1 h Heartbeat-Abstand muss genau der initiale
    # Heartbeat ausgeführt werden.
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql 'CREATE TABLE IF NOT EXISTS hotfix10_batch_test(n INTEGER);DELETE FROM hotfix10_batch_test;'|Out-Null
    $batchHeartbeatCounter=@{Count=0}
    $batchStatements=New-Object System.Collections.Generic.List[string]
    foreach($n in 1..120){$batchStatements.Add("INSERT INTO hotfix10_batch_test(n) VALUES($n);")}
    Invoke-FsSqlBatch -SqlitePath $sqlite -DatabasePath $db -Statements $batchStatements.ToArray() -Immediate -BatchSize 20 -Heartbeat {$batchHeartbeatCounter.Count=[int]$batchHeartbeatCounter.Count+1} -HeartbeatSeconds 3600
    if([int]$batchHeartbeatCounter.Count -ne 1){throw "SQL-Batch führte $($batchHeartbeatCounter.Count) Heartbeats statt genau einem aus."}
    $batchCount=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM hotfix10_batch_test;')
    if([int]$batchCount[0].count -ne 120){throw 'SQL-Batch-Regressionsprüfung verlor Datensätze.'}

    # Zwei Prozesse schreiben gleichzeitig. Die Dateisperre muss sie serialisieren,
    # ohne SQLITE_BUSY und ohne Datenverlust.
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql 'CREATE TABLE IF NOT EXISTS hotfix10_writer_test(id INTEGER PRIMARY KEY AUTOINCREMENT,worker TEXT,n INTEGER);DELETE FROM hotfix10_writer_test;'|Out-Null
    $modulePath=Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1'
    $writerJobs=@()
    foreach($writerName in @('a','b')){
        $writerJobs+=Start-Job -ScriptBlock {
            param($ModulePath,$Sqlite,$Database,$Writer)
            Import-Module $ModulePath -Force -DisableNameChecking
            for($i=1;$i -le 40;$i++){
                Invoke-FsSqlite -SqlitePath $Sqlite -DatabasePath $Database -Sql "INSERT INTO hotfix10_writer_test(worker,n) VALUES($(ConvertTo-FsSqlLiteral $Writer),$i);"|Out-Null
            }
        } -ArgumentList $modulePath,$sqlite,$db,$writerName
    }
    $writerJobs|Wait-Job|Out-Null
    $writerErrors=@($writerJobs|Receive-Job -ErrorAction SilentlyContinue -ErrorVariable writerJobErrors)
    $writerJobs|Remove-Job -Force
    if(@($writerJobErrors).Count -gt 0){throw "Paralleler Schreibtest meldete Fehler: $($writerJobErrors -join '; ')"}
    $writerCount=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM hotfix10_writer_test;')
    if([int]$writerCount[0].count -ne 80){throw 'Paralleler Schreibtest verlor Datensätze.'}

    # Ein festhängender sqlite3-Prozess darf den gemeinsamen Schreibslot nicht
    # unbegrenzt halten. Der Test erzwingt ein kurzes Zeitlimit und prüft danach,
    # dass ein normaler Schreibzugriff wieder möglich ist.
    $timeoutObserved=$false
    try{
        Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -ExecutionTimeoutMs 150 -BusyRetries 0 -Sql @"
CREATE TABLE IF NOT EXISTS hotfix10_timeout_test(x INTEGER);
DELETE FROM hotfix10_timeout_test;
WITH RECURSIVE cnt(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM cnt WHERE x<1000000000)
INSERT INTO hotfix10_timeout_test(x) SELECT x FROM cnt;
"@ | Out-Null
    }catch{if($_.Exception.Message -match 'SQLite-Ausführungszeit'){$timeoutObserved=$true}else{throw}}
    if(-not $timeoutObserved){throw 'SQLite-Ausführungszeitwächter wurde nicht ausgelöst.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "INSERT INTO hotfix10_writer_test(worker,n) VALUES('after-timeout',999);"|Out-Null

    # Regressionstest für Start-Job -FilePath: In Windows PowerShell kann
    # $PSScriptRoot im Worker leer sein. Der Worker muss sein ausdrücklich
    # übergebenes Programmverzeichnis verwenden und ohne offene Tasks enden.
    $workerRun=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode 'Status' -Profile 'Fast' -ParametersJson '{}'
    Start-FsStageWorkers -WorkerPath (Join-Path $PSScriptRoot 'FindSeries.Worker.ps1') -Stage 'category' -ProjectId $projectId -RunId $workerRun -Workspace $init.Paths.Root -SqlitePath $sqlite -Config $config -Workers 1 -PollSeconds 1 -TextProgressSeconds 60 -StallWarningSeconds 60 | Out-Null
    Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $workerRun -Status 'completed'
    [void](Set-FsApiCooldown -SqlitePath $sqlite -DatabasePath $db -GateName 'selftest-api' -Seconds 2 -BaseDelayMs 1000)
    $gate=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT next_at_ms,adaptive_delay_ms,last_throttle_at_ms FROM api_gate WHERE name='selftest-api';")
    if($gate.Count -ne 1 -or [long]$gate[0].next_at_ms -le (Get-FsUnixMilliseconds)){throw 'Globaler API-Cooldown wurde nicht gespeichert.'}
    if([int]$gate[0].adaptive_delay_ms -lt 1250 -or [long]$gate[0].last_throttle_at_ms -le 0){throw 'Adaptive API-Verzögerung wurde nach einem Throttle nicht erhöht.'}
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql "UPDATE api_gate SET next_at_ms=0 WHERE name='selftest-api';"|Out-Null
    $slot=Acquire-FsApiSlot -SqlitePath $sqlite -DatabasePath $db -GateName 'selftest-api' -DelayMs 1000
    if([int]$slot.EffectiveDelayMs -lt 1250){throw 'API-Gate verwendet die adaptive Verzögerung nicht.'}

    $owner='selftest-'+$PID
    if(-not(Acquire-FsNamedLock -SqlitePath $sqlite -DatabasePath $db -Name 'selftest-lock' -Owner $owner -LeaseSeconds 30 -WaitSeconds 2)){throw 'Named Lock konnte nicht erworben werden.'}
    Release-FsNamedLock -SqlitePath $sqlite -DatabasePath $db -Name 'selftest-lock' -Owner $owner

    # Multi-key media identity: create two independent rows, then bridge them by SHA-1 and Page-ID.
    $now=Get-FsUtcNowText
    $shaA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $shaB='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $mediaA=[pscustomobject]@{Title='File:Old_name.jpg';CanonicalTitle='File:Old_name.jpg';PageId=101;Sha1=$shaA;MetadataLevel=1}
    $mediaB=[pscustomobject]@{Title='File:New_name.jpg';CanonicalTitle='File:New_name.jpg';PageId=202;Sha1=$shaB;MetadataLevel=2}
    $statements=New-Object System.Collections.Generic.List[string]
    $statements.Add((Get-FsMediaInsertSql $mediaA $now))
    $statements.Add((Get-FsProjectMediaSql $projectId $mediaA 60 'selftest-a' $now))
    $statements.Add((Get-FsMediaInsertSql $mediaB $now))
    $statements.Add((Get-FsProjectMediaSql $projectId $mediaB 80 'selftest-b' $now))
    Invoke-FsSqlBatch -SqlitePath $sqlite -DatabasePath $db -Statements $statements.ToArray() -Immediate

    $bLookup=Get-FsMediaLookupSqlExpression $mediaB
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
INSERT INTO downloads(media_id,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,created_at,updated_at)
SELECT id,'historical',NULL,123,$(ConvertTo-FsSqlLiteral $shaB),1,$projectId,$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now) FROM media WHERE id=$bLookup;
INSERT INTO download_history(media_id,project_id,source_kind,source_path,status,registered_at,imported_at)
SELECT id,$projectId,'selftest','selftest-registry','vorhanden',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now) FROM media WHERE id=$bLookup;
"@ | Out-Null

    $bridge=[pscustomobject]@{Title='File:Renamed_bridge.jpg';CanonicalTitle='File:Renamed_bridge.jpg';PageId=202;Sha1=$shaA;MetadataLevel=2}
    Invoke-FsSqlBatch -SqlitePath $sqlite -DatabasePath $db -Statements @((Get-FsMediaInsertSql $bridge (Get-FsUtcNowText))) -Immediate
    $conflicts=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM media_identity_conflicts;')
    if([int]$conflicts[0].count -lt 1){throw 'Identitätskonflikt wurde nicht erkannt.'}
    $merged=Repair-FsMediaIdentityConflicts -SqlitePath $sqlite -DatabasePath $db -MaxPairs 10 -QueueOnly
    if($merged -lt 1){throw 'Doppelte Medien wurden nicht zusammengeführt.'}
    $mediaCount=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM media;')
    $identityCount=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM media_identities;')
    $historyCount=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'SELECT COUNT(*) count FROM download_history;')
    $projectMediaCount=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT COUNT(*) count,MAX(score) max_score FROM project_media WHERE project_id=$projectId;")
    if([int]$mediaCount[0].count -ne 1){throw 'Mehrschlüssel-Deduplizierung hat nicht auf einen Mediendatensatz reduziert.'}
    if([int]$identityCount[0].count -lt 7){throw 'Nicht alle SHA-1-, Page-ID- und Titelidentitäten wurden erhalten.'}
    if([int]$historyCount[0].count -ne 1){throw 'Downloadhistorie ging beim Merge verloren.'}
    if([int]$projectMediaCount[0].count -ne 1 -or [int]$projectMediaCount[0].max_score -ne 80){throw 'Project-Zuordnung oder Score ging beim Merge verloren.'}


    # HF62 runtime regression: an explicitly mismatched terminal global download
    # must be repaired once, then be claimable as real network work instead of
    # bouncing the project row between pending/running forever.
    $badMedia=[pscustomobject]@{Title='File:HF62_identity_mismatch.jpg';CanonicalTitle='File:HF62_identity_mismatch.jpg';PageId=303;Sha1='cccccccccccccccccccccccccccccccccccccccc';MetadataLevel=2;Url='https://example.invalid/hf62.jpg';MediaType='BITMAP';Mime='image/jpeg';Size=1234}
    $badNow=Get-FsUtcNowText
    $badStatements=New-Object System.Collections.Generic.List[string]
    $badStatements.Add((Get-FsMediaInsertSql $badMedia $badNow))
    $badStatements.Add((Get-FsProjectMediaSql $projectId $badMedia 90 'selftest-hf62' $badNow))
    Invoke-FsSqlBatch -SqlitePath $sqlite -DatabasePath $db -Statements $badStatements.ToArray() -Immediate
    $badLookup=Get-FsMediaLookupSqlExpression $badMedia
    Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Sql @"
INSERT INTO project_downloads(project_id,media_id,status,attempts,updated_at)
SELECT $projectId,id,'pending',3346,$(ConvertTo-FsSqlLiteral $badNow) FROM media WHERE id=$badLookup;
INSERT INTO downloads(media_id,status,local_path,bytes,verified_sha1,historical_complete,owner_project_id,attempts,created_at,updated_at)
SELECT id,'historical',NULL,999,'dddddddddddddddddddddddddddddddddddddddd',1,$projectId,0,$(ConvertTo-FsSqlLiteral $badNow),$(ConvertTo-FsSqlLiteral $badNow) FROM media WHERE id=$badLookup;
"@ | Out-Null
    $repairCount=Repair-FsInvalidDownloadIdentityRows -ProjectId $projectId -SqlitePath $sqlite -DatabasePath $db
    if([int]$repairCount -ne 1){throw 'HF62 hat den absichtlich inkonsistenten Terminal-Download nicht genau einmal repariert.'}
    $repaired=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT pd.status project_status,pd.attempts project_attempts,d.status global_status,d.historical_complete,d.local_path,d.verified_sha1 FROM project_downloads pd JOIN downloads d ON d.media_id=pd.media_id WHERE pd.project_id=$projectId AND pd.media_id=(SELECT id FROM media WHERE id=$badLookup);")
    if($repaired.Count -ne 1 -or [string]$repaired[0].project_status -ne 'pending' -or [int]$repaired[0].project_attempts -ne 0 -or [string]$repaired[0].global_status -ne 'pending' -or [int]$repaired[0].historical_complete -ne 0 -or $null -ne $repaired[0].verified_sha1){
        throw 'HF62-Download-Identitätsreparatur hinterlässt keinen sauberen pending-Zustand.'
    }
    $repairRun=New-FsRun -SqlitePath $sqlite -DatabasePath $db -ProjectId $projectId -Mode 'Status' -Profile 'Fast' -ParametersJson '{}'
    $repairConfig=Get-FsProjectConfig -Profile 'Fast' -ProfilesPath (Join-Path $PSScriptRoot 'Config\profiles.json')
    $claim=@(Claim-FsDownloadTasks -ProjectId $projectId -RunId $repairRun -Worker 'hf62-selftest-worker' -Config $repairConfig -SqlitePath $sqlite -DatabasePath $db -LeaseSeconds 14400 -Limit 1)
    if($claim.Count -ne 1 -or [string]$claim[0].global_download_status -ne 'running' -or [string]$claim[0].global_download_owner -ne 'hf62-selftest-worker'){
        throw 'HF62-reparierter Download wird nicht als echte Downloadarbeit atomar geclaimt.'
    }
    Complete-FsRun -SqlitePath $sqlite -DatabasePath $db -RunId $repairRun -Status 'completed'

    $journal=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql 'PRAGMA journal_mode;')
    $tables=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT COUNT(*) count FROM sqlite_master WHERE type='table';")
    $searchSource64=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1') -Raw
    if($searchSource64 -notmatch 'function\s+Invoke-FsCategoryResultBulkWrite' -or
       $searchSource64 -notmatch 'fs_category_resolved' -or
       $searchSource64 -notmatch "record_type='category'" -or
       $searchSource64 -notmatch 'function\s+Invoke-FsCategoryQueuePrune'){
        throw 'HF64-Category-Bulkpfad oder Category-Telemetrie fehlt.'
    }
    $callsSource64=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'aufrufe.txt') -Raw
    if($callsSource64 -notmatch 'Category\.Workers=4' -or $callsSource64 -notmatch 'Category\.DriftGuard=Strict'){
        throw 'HF64-Cat_Dentistry-Performanceprofil fehlt.'
    }

    # HF65 download-performance regression.
    $hf65Indexes=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('ix_project_downloads_pending','ix_project_downloads_failed_retry') ORDER BY name;")
    if($hf65Indexes.Count -ne 2){throw 'HF65 partielle Download-Claim-Indizes fehlen in SQLite.'}
    $hf65Plan=@(Invoke-FsSqlite -SqlitePath $sqlite -DatabasePath $db -Query -Sql "EXPLAIN QUERY PLAN SELECT media_id FROM project_downloads INDEXED BY ix_project_downloads_pending WHERE project_id=$projectId AND status='pending' ORDER BY media_id LIMIT 12;")
    if(($hf65Plan | ForEach-Object {[string]$_.detail}) -join ' ' -notmatch 'ix_project_downloads_pending'){throw 'HF65 Pending-Claim verwendet den partiellen Index nicht.'}
    if($searchSource64 -notmatch 'function\s+Reset-FsDownloadClaimConflict' -or
       $searchSource64 -notmatch 'return ''__FS_RETRY__''' -or
       $searchSource64 -match 'SELECT m\.\*,d\.status download_status'){
        throw 'HF65 Claim-Spin-Schutz oder Prefetch-Eliminierung des zweiten Worker-Lookups fehlt.'
    }
    if($callsSource64 -notmatch 'Download\.ClaimBatchSize=8' -or
       $callsSource64 -notmatch 'Download\.CompletionBatchSize=4' -or
       $callsSource64 -notmatch 'Download\.AutoTuneMinDelayMs=1000' -or
       $callsSource64 -notmatch 'Download\.AutoTuneMinImprovementPct=2'){
        throw 'HF65 Cat_Dentistry-Performanceprofil (Claim-Batch 8 / Ergebnis-Batch 4 / Throughput-AutoTune) fehlt.'
    }
    if($searchSource64 -notmatch 'function\s+Submit-FsDownloadWorkItem' -or
       $searchSource64 -notmatch 'function\s+Flush-FsDownloadCompletionQueue' -or
       $workerSource -notmatch 'Flush-FsDownloadCompletionQueue'){
        throw 'HF65 gebündelte Download-Finalisierung oder Worker-Endflush fehlt.'
    }
    if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'New-FindSeriesLocalWorkspace.ps1') -PathType Leaf)){
        throw 'HF65 Hilfsskript für lokale DB bei externem Media-Verzeichnis fehlt.'
    }
    Write-Host 'FindSeries V5.0.14 Hotfix 66 Selbsttest: PASS' -ForegroundColor Green
    Write-Host ("SQLite: {0}" -f (& $sqlite -version)) -ForegroundColor Gray
    Write-Host ("Journal-Modus: {0}; Tabellen: {1}; Identitäten: {2}; Workspace: {3}" -f $journal[0].journal_mode,$tables[0].count,$identityCount[0].count,$init.Paths.Root) -ForegroundColor Gray
}
finally {
    if($created -and -not $Keep -and (Test-Path -LiteralPath $Workspace)){Remove-Item -LiteralPath $Workspace -Recurse -Force -ErrorAction SilentlyContinue}
}

# HF62-Parserregression
$hf44SearchSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1') -Raw
$invalidBurstVariablePattern='\$burstNumber'+':'
if($hf44SearchSource -match $invalidBurstVariablePattern){throw ('HF62-Parserregression: Ungeklammerter Variablenverweis $burstNumber'+': gefunden.')}
