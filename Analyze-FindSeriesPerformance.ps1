# Parameterlose Kurzanalyse der aktiven FindSeries-performance.csv.
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$columns=@('timestamp_utc','run_id','project_id','worker','stage','record_type','operation','task_id','query_text','language','attempt','hits','input_count','unique_count','duplicate_count','new_project_media','gate_ms','http_parse_ms','transform_ms','sql_build_ms','bulk_sqlite_ms','lock_wait_ms','sqlite_ms','json_parse_ms','task_complete_ms','total_ms','sql_chars','rows_returned','success','error')

function N($Value){
    $result=0.0
    if([double]::TryParse([string]$Value,[Globalization.NumberStyles]::Any,[Globalization.CultureInfo]::InvariantCulture,[ref]$result)){return $result}
    return 0.0
}
function IsTrue($Value){return ([string]$Value).ToLowerInvariant() -eq 'true'}
function Percentile([double[]]$Values,[double]$Percent){
    $sorted=@($Values|Sort-Object)
    if($sorted.Count -eq 0){return 0.0}
    $index=[Math]::Ceiling(($Percent/100.0)*$sorted.Count)-1
    return [double]$sorted[[Math]::Max(0,[Math]::Min($sorted.Count-1,$index))]
}
function Stats([double[]]$Values){
    $a=@($Values|Where-Object{-not[double]::IsNaN($_) -and -not[double]::IsInfinity($_)})
    if($a.Count -eq 0){return [pscustomobject]@{Count=0;Sum=0.0;Avg=0.0;Median=0.0;P95=0.0;Max=0.0}}
    $sum=[double](($a|Measure-Object -Sum).Sum)
    return [pscustomobject]@{Count=$a.Count;Sum=$sum;Avg=$sum/$a.Count;Median=(Percentile $a 50);P95=(Percentile $a 95);Max=[double](($a|Measure-Object -Maximum).Maximum)}
}
function Fms([double]$Value){return ('{0:N1} ms' -f $Value)}
function Fs([double]$Value){return ('{0:N2} s' -f ($Value/1000.0))}
function Add-Line([Collections.Generic.List[string]]$Lines,[string]$Text=''){[void]$Lines.Add($Text);Write-Host $Text}

Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$workspaceCandidates=New-Object Collections.Generic.List[string]
try{[void]$workspaceCandidates.Add((Resolve-FsConfiguredWorkspace -ApplicationRoot $PSScriptRoot))}catch{}
[void]$workspaceCandidates.Add('E:\Temp\FindSeriesV5-Workspace')
[void]$workspaceCandidates.Add((Join-Path $PSScriptRoot 'Workspace'))
$workspace=$null;$csv=$null
foreach($candidate in @($workspaceCandidates|Select-Object -Unique)){
    if([string]::IsNullOrWhiteSpace([string]$candidate)){continue}
    $candidateCsv=Join-Path $candidate 'Diagnostics\performance.csv'
    if(Test-Path -LiteralPath $candidateCsv -PathType Leaf){$workspace=[IO.Path]::GetFullPath($candidate);$csv=$candidateCsv;break}
    $fallback=Get-ChildItem -LiteralPath (Join-Path $candidate 'Diagnostics') -Filter 'performance*.csv' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if($null -ne $fallback){$workspace=[IO.Path]::GetFullPath($candidate);$csv=$fallback.FullName;break}
}
if([string]::IsNullOrWhiteSpace($csv)){throw 'performance.csv wurde weder im konfigurierten noch im Standard-Workspace gefunden.'}

$firstLine=[string](Get-Content -LiteralPath $csv -TotalCount 1)
if($firstLine -match '^timestamp_utc,run_id,'){$rows=@(Import-Csv -LiteralPath $csv)}
else{$rows=@(Get-Content -LiteralPath $csv | ConvertFrom-Csv -Header $columns)}
if($rows.Count -eq 0){throw 'performance.csv enthält keine Datensätze.'}

$runIds=@($rows|Where-Object{$_.run_id -match '^\d+$'}|ForEach-Object{[long]$_.run_id}|Sort-Object -Unique)
if($runIds.Count -eq 0){throw 'Keine numerische run_id in performance.csv gefunden.'}
$runId=[long]$runIds[-1]
$selected=@($rows|Where-Object{[long]$_.run_id -eq $runId})
$downloads=@($selected|Where-Object{$_.record_type -eq 'download'})
$items=@($selected|Where-Object{$_.record_type -eq 'download_item'})
$sql=@($selected|Where-Object{$_.record_type -eq 'sql'})
$lines=New-Object Collections.Generic.List[string]
$reportPath=Join-Path $workspace 'Diagnostics\performance-analysis.txt'

Add-Line $lines 'FindSeries Performance-Kurzanalyse'
Add-Line $lines ('Zeitpunkt: {0}' -f (Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))
Add-Line $lines ('Run: {0} | CSV: {1} | Datensätze: {2:N0}' -f $runId,$csv,$selected.Count)
Add-Line $lines

if($downloads.Count -gt 0){
    $successful=@($downloads|Where-Object{IsTrue $_.success})
    $gate=Stats @($successful|ForEach-Object{N $_.gate_ms})
    $http=Stats @($successful|ForEach-Object{N $_.http_parse_ms})
    $total=Stats @($successful|ForEach-Object{N $_.total_ms})
    $bytes=[double](($successful|ForEach-Object{N $_.hits}|Measure-Object -Sum).Sum)
    $gateShare=if($total.Sum -gt 0){100.0*$gate.Sum/$total.Sum}else{0.0}
    $netMBps=if($http.Sum -gt 0){($bytes/1MB)/($http.Sum/1000.0)}else{0.0}
    $overallMBps=if($total.Sum -gt 0){($bytes/1MB)/($total.Sum/1000.0)}else{0.0}
    Add-Line $lines 'Originaldatei-Downloads:'
    Add-Line $lines ('  Erfolgreich: {0:N0} | Fehlgeschlagen/Retry: {1:N0} | Datenmenge: {2:N2} GiB' -f $successful.Count,($downloads.Count-$successful.Count),($bytes/1GB))
    Add-Line $lines ('  API-Gate: Mittel {0}; Median {1}; P95 {2}; Anteil an Gesamtzeit {3:N1} %' -f (Fms $gate.Avg),(Fms $gate.Median),(Fms $gate.P95),$gateShare)
    Add-Line $lines ('  HTTP-Transfer: Mittel {0}; Median {1}; P95 {2}; Netzrate aggregiert {3:N2} MB/s' -f (Fms $http.Avg),(Fms $http.Median),(Fms $http.P95),$netMBps)
    Add-Line $lines ('  Downloadversuch gesamt: Mittel {0}; Median {1}; P95 {2}; effektive Datenrate inkl. Gate {3:N2} MB/s' -f (Fms $total.Avg),(Fms $total.Median),(Fms $total.P95),$overallMBps)
    if($gateShare -ge 50){Add-Line $lines ('  BEFUND: Das API-Gate dominiert mit {0:N1} % der gemessenen Zeit.' -f $gateShare)}
    elseif($http.Avg -gt 5000){Add-Line $lines '  BEFUND: Der HTTP-/Datentransfer dominiert.'}
    else{Add-Line $lines '  BEFUND: Gate und HTTP erklären die Gesamtdauer nicht allein; Detailphasen prüfen.'}
    Add-Line $lines
}

if($items.Count -gt 0){
    $itemSuccess=@($items|Where-Object{IsTrue $_.success})
    $phaseDefinitions=@(
        @{Name='Task beanspruchen';Column='transform_ms'},
        @{Name='Metadaten/Wiederverwendung prüfen';Column='sql_build_ms'},
        @{Name='Zielpfad vorbereiten';Column='bulk_sqlite_ms'},
        @{Name='API-Gate/Cooldown';Column='gate_ms'},
        @{Name='HTTP-Dateitransfer';Column='http_parse_ms'},
        @{Name='Datei verschieben';Column='lock_wait_ms'},
        @{Name='SHA1 prüfen';Column='sqlite_ms'},
        @{Name='DB-Abschluss speichern';Column='task_complete_ms'},
        @{Name='Sonstiger Overhead';Column='json_parse_ms'}
    )
    Add-Line $lines 'Vollständige Download-Arbeitseinheiten (HF50-Detailmessung):'
    foreach($phase in $phaseDefinitions){
        $st=Stats @($itemSuccess|ForEach-Object{N ($_.PSObject.Properties[[string]$phase.Column].Value)})
        Add-Line $lines ('  {0,-32} Gesamt {1,9:N2} s | Mittel {2,9:N1} ms | P95 {3,9:N1} ms' -f $phase.Name,($st.Sum/1000.0),$st.Avg,$st.P95)
    }
    $itemTotal=Stats @($itemSuccess|ForEach-Object{N $_.total_ms})
    Add-Line $lines ('  {0,-32} Gesamt {1,9:N2} s | Mittel {2,9:N1} ms | P95 {3,9:N1} ms' -f 'Arbeitseinheit komplett',($itemTotal.Sum/1000.0),$itemTotal.Avg,$itemTotal.P95)
    Add-Line $lines '  Ergebnisse:'
    $items|Group-Object query_text|Sort-Object Count -Descending|ForEach-Object{Add-Line $lines ('    {0,-28} {1,7:N0}' -f $_.Name,$_.Count)}
    Add-Line $lines
}else{
    Add-Line $lines 'Hinweis: Download-Detailphasen stehen erst für Läufe ab HF50 zur Verfügung.'
    Add-Line $lines
}

if($sql.Count -gt 0){
    $lock=Stats @($sql|ForEach-Object{N $_.lock_wait_ms})
    $exec=Stats @($sql|ForEach-Object{N $_.sqlite_ms})
    $totalSql=Stats @($sql|ForEach-Object{N $_.total_ms})
    Add-Line $lines 'SQLite:'
    Add-Line $lines ('  Aufrufe: {0:N0} | Lock-Wartezeit gesamt {1:N2} s, P95 {2:N1} ms | Ausführung gesamt {3:N2} s, P95 {4:N1} ms' -f $sql.Count,($lock.Sum/1000),$lock.P95,($exec.Sum/1000),$exec.P95)
    Add-Line $lines ('  SQL-Gesamtzeit: {0:N2} s | langsamster Aufruf: {1:N2} s' -f ($totalSql.Sum/1000),($totalSql.Max/1000))
    Add-Line $lines
}

try{
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalMem=[double]$os.TotalVisibleMemorySize*1KB
    $freeMem=[double]$os.FreePhysicalMemory*1KB
    $usedPercent=if($totalMem -gt 0){100.0*($totalMem-$freeMem)/$totalMem}else{0}
    $processes=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{($_.Name -match '^(powershell|pwsh|sqlite3)\.exe$') -and -not[string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and $_.CommandLine -match 'FindSeries|findseries-v5|performance\.csv'})
    $working=[double](($processes|Measure-Object WorkingSetSize -Sum).Sum)
    Add-Line $lines 'Aktueller Ressourcen-Schnappschuss:'
    Add-Line $lines ('  Physischer Speicher: {0:N1} % belegt; frei {1:N2} GiB von {2:N2} GiB.' -f $usedPercent,($freeMem/1GB),($totalMem/1GB))
    Add-Line $lines ('  Zugeordnete FindSeries-/sqlite-Prozesse: {0}; Working Set zusammen {1:N0} MiB.' -f $processes.Count,($working/1MB))
    foreach($g in @($processes|Group-Object Name|Sort-Object Name)){Add-Line $lines ('    {0,-16} {1,3} Prozess(e)' -f $g.Name,$g.Count)}
    foreach($proc in @($processes|Sort-Object WorkingSetSize -Descending|Select-Object -First 12)){
        $role=if([string]$proc.CommandLine -match 'FindSeries\.Worker\.ps1'){'Worker'}elseif([string]$proc.CommandLine -match 'Show-FindSeriesDownloadMonitor'){'Monitor'}elseif([string]$proc.CommandLine -match 'FindSeries\.ps1'){'Orchestrator'}elseif([string]$proc.Name -ieq 'sqlite3.exe'){'SQLite'}else{'FindSeries'}
        Add-Line $lines ('      PID {0,-7} {1,-12} {2,8:N1} MiB' -f $proc.ProcessId,$role,([double]$proc.WorkingSetSize/1MB))
    }
    try{
        $memoryPerf=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        Add-Line $lines ('  Paging aktuell: Page Reads/s {0:N0}; Pages Input/s {1:N0}.' -f ([double]$memoryPerf.PageReadsPersec),([double]$memoryPerf.PagesInputPersec))
    }catch{}
    try{
        $driveRoot=[IO.Path]::GetPathRoot($workspace).TrimEnd('\')
        if($driveRoot -match '^[A-Za-z]:$'){
            $drive=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $driveRoot) -ErrorAction Stop
            Add-Line $lines ('  Laufwerk {0}: frei {1:N1} GiB von {2:N1} GiB ({3:N1} %).' -f $driveRoot,([double]$drive.FreeSpace/1GB),([double]$drive.Size/1GB),$(if([double]$drive.Size -gt 0){100.0*[double]$drive.FreeSpace/[double]$drive.Size}else{0}))
        }
    }catch{}
    Add-Line $lines '  Größte Prozesse im System:'
    Get-Process -ErrorAction SilentlyContinue|Sort-Object WorkingSet64 -Descending|Select-Object -First 8|ForEach-Object{
        Add-Line $lines ('    {0,-24} PID {1,-7} {2,8:N1} MiB' -f $_.ProcessName,$_.Id,([double]$_.WorkingSet64/1MB))
    }
    if($usedPercent -ge 85){Add-Line $lines '  WARNUNG: Hoher Speicherdruck kann Hard Faults/Paging und langsame Explorer-Kopiervorgänge verursachen.'}
    Add-Line $lines
}catch{Add-Line $lines ('Ressourcenstatus nicht lesbar: {0}' -f $_.Exception.Message);Add-Line $lines}

Add-Line $lines ('Bericht gespeichert: {0}' -f $reportPath)
[IO.File]::WriteAllLines($reportPath,$lines,(New-Object Text.UTF8Encoding($true)))
