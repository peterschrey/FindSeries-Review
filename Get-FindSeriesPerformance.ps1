# Laufende oder abgeschlossene FindSeries-Profilingdaten auswerten.
[CmdletBinding()]
param(
    [string]$Workspace,
    [long]$RunId=0,
    [ValidateRange(1,200)][int]$LastQueries=15,
    [ValidateRange(1,200)][int]$SlowSql=15,
    [ValidateRange(1,200)][int]$SlowRequests=15,
    [string]$CsvPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $PSScriptRoot
if([string]::IsNullOrWhiteSpace($CsvPath)){$CsvPath=Join-Path $Workspace 'Diagnostics\performance.csv'}
if(-not(Test-Path -LiteralPath $CsvPath -PathType Leaf)){throw "Profilingdatei nicht gefunden: $CsvPath"}
$performanceColumns=@('timestamp_utc','run_id','project_id','worker','stage','record_type','operation','task_id','query_text','language','attempt','hits','input_count','unique_count','duplicate_count','new_project_media','gate_ms','http_parse_ms','transform_ms','sql_build_ms','bulk_sqlite_ms','lock_wait_ms','sqlite_ms','json_parse_ms','task_complete_ms','total_ms','sql_chars','rows_returned','success','error')
$firstLine=[string](Get-Content -LiteralPath $CsvPath -TotalCount 1)
if($firstLine -match '^timestamp_utc,run_id,'){$rows=@(Import-Csv -LiteralPath $CsvPath)}
else{$rows=@(Get-Content -LiteralPath $CsvPath | ConvertFrom-Csv -Header $performanceColumns)}
if($rows.Count -eq 0){Write-Host 'Noch keine Profilingdaten vorhanden.' -ForegroundColor DarkYellow;return}
function N($v){$d=0.0;if([double]::TryParse([string]$v,[Globalization.NumberStyles]::Any,[Globalization.CultureInfo]::InvariantCulture,[ref]$d)){return $d};return 0.0}
function IsTrue($v){return ([string]$v).ToLowerInvariant() -eq 'true'}
function Get-Percentile([double[]]$Values,[double]$Percent){
    $a=@($Values|Sort-Object)
    if($a.Count -eq 0){return 0.0}
    $index=[Math]::Ceiling(($Percent/100.0)*$a.Count)-1
    $index=[Math]::Max(0,[Math]::Min($a.Count-1,$index))
    return [double]$a[$index]
}
function Get-Stats([double[]]$Values){
    $a=@($Values)
    if($a.Count -eq 0){return [pscustomobject]@{Count=0;Sum=0.0;Avg=0.0;Median=0.0;P95=0.0;Max=0.0}}
    $sum=($a|Measure-Object -Sum).Sum
    return [pscustomobject]@{
        Count=$a.Count;Sum=[double]$sum;Avg=[double]$sum/$a.Count;
        Median=(Get-Percentile $a 50);P95=(Get-Percentile $a 95);Max=($a|Measure-Object -Maximum).Maximum
    }
}
function Get-SqlGroup([string]$Operation){
    switch -Regex ($Operation) {
        '^QUERY-BULK' {return 'Query-Bulk'}
        '^SELECT CASE WHEN status=' {return 'Statuszählung'}
        '^SELECT COALESCE\(query_text' {return 'Aktive Tasks'}
        '^SELECT COUNT\(\*\) count FROM .*lease_until' {return 'Lease-Prüfung'}
        '^UPDATE .*lease_until' {return 'Lease-Erneuerung'}
        '^BEGIN IMMEDIATE; UPDATE .*SET lease_until=' {return 'Lease-Erneuerung'}
        '^BEGIN IMMEDIATE; UPDATE .*status=.running.' {return 'Task-Claim'}
        '^BEGIN IMMEDIATE; INSERT OR IGNORE INTO api_gate' {return 'API-Gate'}
        '^(INSERT INTO events|UPDATE runs)' {return 'Run/Ereignis'}
        default {return 'Sonstiges'}
    }
}
$runIds=@($rows|Where-Object{$_.run_id -match '^\d+$'}|ForEach-Object{[long]$_.run_id}|Sort-Object -Unique)
if($RunId -le 0 -and $runIds.Count -gt 0){$RunId=[long]$runIds[-1]}
$selected=@($rows|Where-Object{[long]$_.run_id -eq $RunId})
if($selected.Count -eq 0){throw "Keine Profilingdaten für Run $RunId."}
$queryAll=@($selected|Where-Object{$_.record_type -eq 'query'})
$query=@($queryAll|Where-Object{IsTrue $_.success})
$queryFailed=@($queryAll|Where-Object{-not (IsTrue $_.success)})
$sql=@($selected|Where-Object{$_.record_type -eq 'sql'})
$api=@($selected|Where-Object{$_.record_type -eq 'api'})
$downloadItems=@($selected|Where-Object{$_.record_type -eq 'download_item'})
Write-Host ''
Write-Host ("FindSeries Profiling – Run {0}" -f $RunId) -ForegroundColor Cyan
Write-Host ("CSV: {0}; Datensätze: {1}; API-Aufrufe: {2}; Query-Seiten erfolgreich/fehlgeschlagen: {3}/{4}; SQL-Aufrufe: {5}; Download-Detailzeilen: {6}" -f $CsvPath,$selected.Count,$api.Count,$query.Count,$queryFailed.Count,$sql.Count,$downloadItems.Count) -ForegroundColor Gray

if($api.Count -gt 0){
    $apiSuccess=@($api|Where-Object{IsTrue $_.success});$apiFailed=@($api|Where-Object{-not (IsTrue $_.success)})
    $gateStats=Get-Stats @($api|ForEach-Object{N $_.gate_ms})
    $httpStats=Get-Stats @($api|ForEach-Object{N $_.http_parse_ms})
    $totalStats=Get-Stats @($api|ForEach-Object{N $_.total_ms})
    $retryAttempts=@($api|Where-Object{(N $_.attempt) -gt 1}).Count
    Write-Host '';Write-Host 'Web-/API-Aufrufe:' -ForegroundColor Cyan
    Write-Host ("Aufrufe {0}; erfolgreich {1}; fehlgeschlagen {2}; zusätzliche Retry-Aufrufe {3}" -f $api.Count,$apiSuccess.Count,$apiFailed.Count,$retryAttempts) -ForegroundColor Gray
    @(
        [pscustomobject]@{Phase='API-Gate/Cooldown';Anzahl=$gateStats.Count;Gesamt_s=[Math]::Round($gateStats.Sum/1000,2);Mittel_ms=[Math]::Round($gateStats.Avg,1);Median_ms=[Math]::Round($gateStats.Median,1);P95_ms=[Math]::Round($gateStats.P95,1);Maximum_ms=[Math]::Round($gateStats.Max,1)},
        [pscustomobject]@{Phase='HTTP inkl. JSON';Anzahl=$httpStats.Count;Gesamt_s=[Math]::Round($httpStats.Sum/1000,2);Mittel_ms=[Math]::Round($httpStats.Avg,1);Median_ms=[Math]::Round($httpStats.Median,1);P95_ms=[Math]::Round($httpStats.P95,1);Maximum_ms=[Math]::Round($httpStats.Max,1)},
        [pscustomobject]@{Phase='API-Aufruf gesamt';Anzahl=$totalStats.Count;Gesamt_s=[Math]::Round($totalStats.Sum/1000,2);Mittel_ms=[Math]::Round($totalStats.Avg,1);Median_ms=[Math]::Round($totalStats.Median,1);P95_ms=[Math]::Round($totalStats.P95,1);Maximum_ms=[Math]::Round($totalStats.Max,1)}
    )|Format-Table -AutoSize
    Write-Host 'API-Aufrufe nach Endpunkt/Modul:' -ForegroundColor Cyan
    $api|Group-Object operation|ForEach-Object{
        $g=@($_.Group);$h=Get-Stats @($g|ForEach-Object{N $_.http_parse_ms})
        [pscustomobject]@{Operation=$_.Name;Aufrufe=$g.Count;Erfolgreich=@($g|Where-Object{IsTrue $_.success}).Count;Fehler=@($g|Where-Object{-not (IsTrue $_.success)}).Count;HTTP_gesamt_s=[Math]::Round($h.Sum/1000,2);HTTP_mittel_ms=[Math]::Round($h.Avg,1);HTTP_P95_ms=[Math]::Round($h.P95,1)}
    }|Sort-Object HTTP_gesamt_s -Descending|Format-Table -AutoSize -Wrap
    Write-Host 'Langsamste Web-/API-Aufrufe:' -ForegroundColor Cyan
    $api|Sort-Object {[double](N $_.total_ms)} -Descending|Select-Object -First $SlowRequests operation,query_text,attempt,@{n='Gate_s';e={[Math]::Round((N $_.gate_ms)/1000,2)}},@{n='HTTP_s';e={[Math]::Round((N $_.http_parse_ms)/1000,2)}},@{n='Gesamt_s';e={[Math]::Round((N $_.total_ms)/1000,2)}},success,error|Format-Table -AutoSize -Wrap
    if($apiFailed.Count -gt 0){
        Write-Host 'API-Fehler/Retry-Ursachen:' -ForegroundColor DarkYellow
        $apiFailed|Group-Object error|Sort-Object Count -Descending|Select-Object -First 10 Count,@{n='Fehler';e={$_.Name}}|Format-Table -AutoSize -Wrap
    }
}else{Write-Host '';Write-Host 'Keine Web-/API-Aufrufe im gewählten Run protokolliert.' -ForegroundColor DarkYellow}

if($query.Count -gt 0){
    $phase=@(
        [pscustomobject]@{Phase='API-Gate/Cooldown';Ms=($query|ForEach-Object{N $_.gate_ms}|Measure-Object -Sum).Sum},
        [pscustomobject]@{Phase='HTTP + JSON';Ms=($query|ForEach-Object{N $_.http_parse_ms}|Measure-Object -Sum).Sum},
        [pscustomobject]@{Phase='Treffer transformieren';Ms=($query|ForEach-Object{N $_.transform_ms}|Measure-Object -Sum).Sum},
        [pscustomobject]@{Phase='SQL erzeugen';Ms=($query|ForEach-Object{N $_.sql_build_ms}|Measure-Object -Sum).Sum},
        [pscustomobject]@{Phase='Bulk-Datenbank gesamt';Ms=($query|ForEach-Object{N $_.bulk_sqlite_ms}|Measure-Object -Sum).Sum},
        [pscustomobject]@{Phase='Taskabschluss';Ms=($query|ForEach-Object{N $_.task_complete_ms}|Measure-Object -Sum).Sum}
    )
    $total=($query|ForEach-Object{N $_.total_ms}|Measure-Object -Sum).Sum
    Write-Host '';Write-Host 'Zeitanteile abgeschlossener Query-Seiten:' -ForegroundColor Cyan
    $phase|ForEach-Object{[pscustomobject]@{Phase=$_.Phase;Sekunden=[Math]::Round($_.Ms/1000,2);Anteil=$(if($total -gt 0){[Math]::Round($_.Ms*100/$total,1)}else{0})}}|Format-Table -AutoSize
    $hits=($query|ForEach-Object{N $_.hits}|Measure-Object -Sum).Sum;$new=($query|ForEach-Object{N $_.new_project_media}|Measure-Object -Sum).Sum
    $yield=if($hits -gt 0){100.0*$new/$hits}else{0}
    Write-Host ("Query-Gesamtzeit {0:N1}s; Mittel {1:N1}s/Seite; Treffer {2:N0}; neu im Projekt {3:N0}; Neuertrag {4:N3}%" -f ($total/1000),($total/1000/$query.Count),$hits,$new,$yield) -ForegroundColor Gray
    Write-Host '';Write-Host 'Langsamste Query-Seiten:' -ForegroundColor Cyan
    $query|Sort-Object {[double](N $_.total_ms)} -Descending|Select-Object -First $LastQueries @{n='Query';e={$_.query_text}},@{n='Treffer';e={[int](N $_.hits)}},@{n='Neu';e={[int](N $_.new_project_media)}},@{n='Gate_s';e={[Math]::Round((N $_.gate_ms)/1000,2)}},@{n='HTTP_s';e={[Math]::Round((N $_.http_parse_ms)/1000,2)}},@{n='DB_s';e={[Math]::Round((N $_.bulk_sqlite_ms)/1000,2)}},@{n='Gesamt_s';e={[Math]::Round((N $_.total_ms)/1000,2)}}|Format-Table -AutoSize -Wrap
}else{Write-Host '';Write-Host 'Noch keine abgeschlossene Query-Seite im Profil.' -ForegroundColor DarkYellow}
if($queryFailed.Count -gt 0){
    Write-Host 'Fehlgeschlagene Query-Seiten:' -ForegroundColor DarkYellow
    $queryFailed|Select-Object -Last $LastQueries query_text,language,@{n='Gesamt_s';e={[Math]::Round((N $_.total_ms)/1000,2)}},error|Format-Table -AutoSize -Wrap
}

if($sql.Count -gt 0){
    $lockStats=Get-Stats @($sql|ForEach-Object{N $_.lock_wait_ms})
    $execStats=Get-Stats @($sql|ForEach-Object{N $_.sqlite_ms})
    $parseStats=Get-Stats @($sql|ForEach-Object{N $_.json_parse_ms})
    $sqlFailed=@($sql|Where-Object{-not (IsTrue $_.success)})
    $sortedExec=@($sql|ForEach-Object{N $_.sqlite_ms}|Sort-Object -Descending)
    $top2Sum=if($sortedExec.Count -gt 0){($sortedExec|Select-Object -First ([Math]::Min(2,$sortedExec.Count))|Measure-Object -Sum).Sum}else{0}
    $rest=@($sortedExec|Select-Object -Skip ([Math]::Min(2,$sortedExec.Count)))
    $restStats=Get-Stats $rest
    Write-Host '';Write-Host 'SQLite-/SQL-Aufrufe:' -ForegroundColor Cyan
    Write-Host ("Aufrufe {0}; erfolgreich {1}; fehlgeschlagen/Timeout {2}" -f $sql.Count,($sql.Count-$sqlFailed.Count),$sqlFailed.Count) -ForegroundColor Gray
    @(
        [pscustomobject]@{Messwert='Lock-Wartezeit';Gesamt_s=[Math]::Round($lockStats.Sum/1000,2);Mittel_ms=[Math]::Round($lockStats.Avg,1);Median_ms=[Math]::Round($lockStats.Median,1);P95_ms=[Math]::Round($lockStats.P95,1);Maximum_ms=[Math]::Round($lockStats.Max,1)},
        [pscustomobject]@{Messwert='SQLite-Ausführung';Gesamt_s=[Math]::Round($execStats.Sum/1000,2);Mittel_ms=[Math]::Round($execStats.Avg,1);Median_ms=[Math]::Round($execStats.Median,1);P95_ms=[Math]::Round($execStats.P95,1);Maximum_ms=[Math]::Round($execStats.Max,1)},
        [pscustomobject]@{Messwert='JSON-Parse';Gesamt_s=[Math]::Round($parseStats.Sum/1000,2);Mittel_ms=[Math]::Round($parseStats.Avg,1);Median_ms=[Math]::Round($parseStats.Median,1);P95_ms=[Math]::Round($parseStats.P95,1);Maximum_ms=[Math]::Round($parseStats.Max,1)}
    )|Format-Table -AutoSize
    if($sql.Count -gt 2){
        Write-Host ("Die zwei langsamsten Aufrufe verursachen {0:N2}s bzw. {1:N1}% der SQLite-Zeit. Ohne diese Ausreißer: {2} Aufrufe, Mittel {3:N1} ms." -f ($top2Sum/1000),$(if($execStats.Sum -gt 0){100*$top2Sum/$execStats.Sum}else{0}),$restStats.Count,$restStats.Avg) -ForegroundColor Gray
    }
    Write-Host 'SQL-Zeit nach Funktionsgruppe:' -ForegroundColor Cyan
    $sql|ForEach-Object{[pscustomobject]@{Group=(Get-SqlGroup ([string]$_.operation));Row=$_}}|Group-Object Group|ForEach-Object{
        $g=@($_.Group|ForEach-Object{$_.Row});$st=Get-Stats @($g|ForEach-Object{N $_.sqlite_ms})
        [pscustomobject]@{Gruppe=$_.Name;Aufrufe=$g.Count;Fehler=@($g|Where-Object{-not (IsTrue $_.success)}).Count;Gesamt_s=[Math]::Round($st.Sum/1000,2);Mittel_ms=[Math]::Round($st.Avg,1);Median_ms=[Math]::Round($st.Median,1);P95_ms=[Math]::Round($st.P95,1);Maximum_s=[Math]::Round($st.Max/1000,2)}
    }|Sort-Object Gesamt_s -Descending|Format-Table -AutoSize
    Write-Host 'Langsamste SQL-Aufrufe:' -ForegroundColor Cyan
    $sql|Sort-Object {[double](N $_.total_ms)} -Descending|Select-Object -First $SlowSql @{n='Operation';e={$_.operation}},@{n='Lock_s';e={[Math]::Round((N $_.lock_wait_ms)/1000,2)}},@{n='SQLite_s';e={[Math]::Round((N $_.sqlite_ms)/1000,2)}},@{n='Gesamt_s';e={[Math]::Round((N $_.total_ms)/1000,2)}},success,error|Format-Table -AutoSize -Wrap
}

Write-Host ''
Write-Host 'Parameterlose Gesamtdiagnose: .\Analyze-FindSeriesPerformance.ps1' -ForegroundColor DarkCyan
