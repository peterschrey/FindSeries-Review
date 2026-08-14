# FindSeries updater: install the highest drop-in from Downloads, test and resume Zahnmedizin.
[CmdletBinding()]
param(
    [string]$Project='Zahnmedizin',
    [string]$Workspace='E:\Temp\FindSeriesV5-Workspace',
    [string]$Downloads=(Join-Path $env:USERPROFILE 'Downloads'),
    [string]$DropinPath,
    [string]$Target=(Get-Location).Path,
    [int]$DownloadWorkers=4,
    [int]$DownloadDelayMs=1370,
    [switch]$SkipRun,
    [switch]$NoMonitor
)

$ErrorActionPreference='Stop'
$Target=[IO.Path]::GetFullPath($Target)
$Workspace=[IO.Path]::GetFullPath($Workspace)

if(-not(Test-Path -LiteralPath (Join-Path $Target 'FindSeries.ps1') -PathType Leaf)){
    throw "FindSeries.ps1 fehlt im aktuellen Zielverzeichnis: $Target"
}

Write-Host "`n=== FindSeries: Update, Test und Resume ===" -ForegroundColor Cyan
Write-Host "Ziel:      $Target"
Write-Host "Workspace: $Workspace"

if(-not[string]::IsNullOrWhiteSpace($DropinPath)){
    $resolvedDropin=Get-Item -LiteralPath ([IO.Path]::GetFullPath($DropinPath)) -ErrorAction Stop
    if($resolvedDropin.PSIsContainer){throw "DropinPath verweist auf ein Verzeichnis: $($resolvedDropin.FullName)"}
    $m=[regex]::Match($resolvedDropin.Name,'hotfix(?<n>\d+)_dropin',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not$m.Success){throw "Ungültiger FindSeries-Drop-in-Dateiname: $($resolvedDropin.Name)"}
    $selected=[pscustomobject]@{File=$resolvedDropin;Hotfix=[int]$m.Groups['n'].Value;Modified=$resolvedDropin.LastWriteTime}
}
else{
    $selected=Get-ChildItem -LiteralPath $Downloads -File -ErrorAction Stop |
        Where-Object {$_.Name -like 'FindSeries_v5_0_14_hotfix*_dropin*.zip'} |
        ForEach-Object {
            $m=[regex]::Match($_.Name,'hotfix(?<n>\d+)_dropin',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if($m.Success){[pscustomobject]@{File=$_;Hotfix=[int]$m.Groups['n'].Value;Modified=$_.LastWriteTime}}
        } |
        Sort-Object @{Expression={$_.Hotfix};Descending=$true},@{Expression={$_.Modified};Descending=$true} |
        Select-Object -First 1
}
if($null -eq $selected){throw "Kein FindSeries-Drop-in gefunden."}
if([int]$selected.Hotfix -lt 66){throw "HF66-Drop-in erforderlich; ausgewählt ist Hotfix $($selected.Hotfix)."}
Write-Host "Drop-in:  $($selected.File.FullName)" -ForegroundColor Green

# Stop only other FindSeries processes; never terminate this updater shell.
Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
$targetPattern=[regex]::Escape($Target)
$workspacePattern=[regex]::Escape($Workspace)
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.Name -match '^(powershell|pwsh|sqlite3)\.exe$' -and
        -not[string]::IsNullOrWhiteSpace($_.CommandLine) -and
        ($_.CommandLine -match 'FindSeries(\.Worker)?\.ps1' -or $_.CommandLine -match $targetPattern -or $_.CommandLine -match $workspacePattern)
    } |
    ForEach-Object {
        Write-Host "Stoppe PID $($_.ProcessId): $($_.Name)" -ForegroundColor DarkYellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 2
Remove-Item -LiteralPath (Join-Path $Workspace 'findseries-v5.db.write.lock') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Workspace 'findseries-v5.db.download-gate') -Force -ErrorAction SilentlyContinue

$stage=Join-Path $env:TEMP ('FindSeries-Dropin-'+[Guid]::NewGuid().ToString('N'))
$backup=Join-Path $env:TEMP ('FindSeries-Backup-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage,$backup -Force | Out-Null
try{
    foreach($relative in @('Config\local.json','Tools\sqlite3.exe')){
        $source=Join-Path $Target $relative
        if(Test-Path -LiteralPath $source -PathType Leaf){
            $saved=Join-Path $backup $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $saved -Force
        }
    }

    Expand-Archive -LiteralPath $selected.File.FullName -DestinationPath $stage -Force
    $versionFile=Get-ChildItem -LiteralPath $stage -Recurse -File -Filter VERSION.txt |
        Where-Object {Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'FindSeries.ps1')} |
        Select-Object -First 1
    if($null -eq $versionFile){throw 'Drop-in enthält keine gültige FindSeries-Wurzel.'}
    $dropinRoot=$versionFile.Directory.FullName
    Get-ChildItem -LiteralPath $dropinRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse -Force
    }

    foreach($relative in @('Config\local.json','Tools\sqlite3.exe')){
        $saved=Join-Path $backup $relative
        if(Test-Path -LiteralPath $saved -PathType Leaf){
            $destination=Join-Path $Target $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $saved -Destination $destination -Force
        }
    }
}finally{
    Remove-Item -LiteralPath $stage,$backup -Recurse -Force -ErrorAction SilentlyContinue
}

Set-Location -LiteralPath $Target
Get-ChildItem -LiteralPath $Target -Recurse -File | Unblock-File
$version=(Get-Content -LiteralPath '.\VERSION.txt' -Raw).Trim()
Write-Host "Installiert: $version" -ForegroundColor Green
if($version -notmatch "hotfix$($selected.Hotfix)$"){
    throw "Versionsabweichung: ZIP Hotfix $($selected.Hotfix), installiert $version."
}

& '.\Test-FindSeriesV5.ps1'

# HF50: Reactivate only tasks made final by the HF47-HF49 telemetry
# regressions (missing GateMs or missing bytes on reused rows). Genuine HTTP
# 404/410 and unrelated download failures remain untouched.
$sqliteExe=Join-Path $Target 'Tools\sqlite3.exe'
$databaseFile=Join-Path $Workspace 'findseries-v5.db'
if((Test-Path -LiteralPath $sqliteExe -PathType Leaf) -and (Test-Path -LiteralPath $databaseFile -PathType Leaf)){
    $projectSql=$Project.Replace("'","''")
    $repairSql=@"
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.hf50_telemetry_repair;
CREATE TEMP TABLE hf50_telemetry_repair(media_id INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO hf50_telemetry_repair(media_id)
SELECT media_id FROM project_downloads
WHERE project_id=(SELECT id FROM projects WHERE name='$projectSql' LIMIT 1)
  AND status='failed'
  AND (
      last_error LIKE '%GateMs%'
      OR lower(last_error) LIKE '%eigenschaft%bytes%gefunden%'
      OR lower(last_error) LIKE '%property%bytes%found%'
  );
INSERT OR IGNORE INTO hf50_telemetry_repair(media_id)
SELECT media_id FROM downloads
WHERE owner_project_id=(SELECT id FROM projects WHERE name='$projectSql' LIMIT 1)
  AND status='failed'
  AND (
      last_error LIKE '%GateMs%'
      OR lower(last_error) LIKE '%eigenschaft%bytes%gefunden%'
      OR lower(last_error) LIKE '%property%bytes%found%'
  );
UPDATE project_downloads
SET status='pending',attempts=0,lease_owner=NULL,lease_until=NULL,last_error=NULL,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE project_id=(SELECT id FROM projects WHERE name='$projectSql' LIMIT 1)
  AND media_id IN (SELECT media_id FROM hf50_telemetry_repair);
UPDATE downloads
SET status='pending',attempts=0,lease_owner=NULL,lease_until=NULL,last_error=NULL,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE owner_project_id=(SELECT id FROM projects WHERE name='$projectSql' LIMIT 1)
  AND media_id IN (SELECT media_id FROM hf50_telemetry_repair);
SELECT COUNT(*) AS repaired_count FROM hf50_telemetry_repair;
COMMIT;
"@
    $repairRaw=@(& $sqliteExe -json $databaseFile $repairSql 2>&1)
    if($LASTEXITCODE -ne 0){throw ("HF50-Telemetrie-Reparatur fehlgeschlagen: {0}" -f ($repairRaw -join "`n"))}
    $repairCount=0
    try{
        $repairRows=@((($repairRaw -join "`n")|ConvertFrom-Json))
        if($repairRows.Count -gt 0){$repairCount=[int]$repairRows[-1].repaired_count}
    }catch{}
    if($repairCount -gt 0){Write-Host ("HF47-HF49-Telemetriefehler reaktiviert: {0} Download-Aufgabe(n)." -f $repairCount) -ForegroundColor Yellow}
}

& '.\Get-FindSeriesStatus.ps1' -Project $Project -RepairStale -Errors
if($SkipRun){return}

$categories=@('Category:Dental_units','Category:Dental_chairs','Category:Dental_equipment')
$keywordGroups=@('Zahnmedizin','Karies::Q2250111','Zahnkaries::Q133772','Zahnarzt','Zahnarztpraxis','Behandlungsstuhl','Zahnarztbohrer','Patient')
$settings=@(
    'Api.Contact=mailto:pschrey@gmail.com',
    'Api.DelayMs=1200','Api.Retries=12',
    'Keyword.MaxLanguages=0','Keyword.MaxSynonymsPerConcept=5','Keyword.MaxQueries=1000','Keyword.MaxResultsPerQuery=1000','Keyword.Workers=1',
    'Category.MaxCategories=1500','Category.MaxFiles=500000','Category.Workers=1',
    'Progress.TextSeconds=10','Progress.StallWarningSeconds=60',
    'Metadata.Level=2',
    'Neighbors.Enabled=true','Neighbors.MaxSeeds=100','Neighbors.MinScore=70','Neighbors.Minutes=180','Neighbors.MaxResultsPerSeed=500','Neighbors.MaxUploaderScan=1000','Neighbors.SeriesExpansion=true',
    'Download.MinScore=40',"Download.Workers=$DownloadWorkers","Download.DelayMs=$DownloadDelayMs",'Download.AutoTune=false','Download.ReuseBatchSize=5000','Download.ClaimBatchSize=4','Download.CompletionBatchSize=4','Download.DelayCacheSeconds=5','Download.ThrottlePauseSeconds=20','Download.ThrottleCarryoverSeconds=900','Download.BurstRecoverySuccesses=8','Download.BurstRecoverySeconds=20','Download.RecoveryWorkerSpacingMs=3000','Download.WorkerStartSpacingSeconds=15','Download.Retries=6','Download.TimeoutSeconds=300',
    'Diagnostics.Profile=true','Diagnostics.Console=false','Diagnostics.SlowSqlMs=500'
)

$runArgs=@{
    Project=$Project
    Mode='Resume'
    Profile='Balanced'
    Category=$categories
    KeywordGroup=$keywordGroups
    Language='de'
    Domain='Dentistry'
    Set=$settings
    Workspace=$Workspace
}
if($NoMonitor){$runArgs.NoMonitor=$true}

& '.\FindSeries.ps1' @runArgs
