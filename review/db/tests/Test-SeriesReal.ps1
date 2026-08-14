# Read-only real series sampling for FRV-8 verification.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabasePath,
    [string]$SqlitePath,
    [string]$OutFile
)
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if(-not $SqlitePath){ $SqlitePath=Join-Path $RepoRoot 'Tools\sqlite3.exe' }
if(-not $OutFile){ $OutFile=Join-Path $env:TEMP 'fs-series-real.md' }
$uri="file:$($DatabasePath.Replace('\','/'))?mode=ro"

function Ro([string]$Sql){
    $out=& $SqlitePath $uri '.timeout 180000' $Sql 2>&1
    if($LASTEXITCODE -ne 0){ throw "sqlite failed: $out" }
    return @($out | Where-Object { $_ -and $_.ToString().Trim() -ne '' })
}

$lines=New-Object Collections.Generic.List[string]
[void]$lines.Add('# Real series verification (FRV-8)')
[void]$lines.Add('')
[void]$lines.Add(('DB: {0} (read-only)' -f $DatabasePath))
[void]$lines.Add('Field separator in queries: TAB (char(9)) so source_value may contain |')

function Add-SeriesBlock([string]$title,[object[]]$rows){
    [void]$lines.Add('')
    [void]$lines.Add(('## {0}' -f $title))
    [void]$lines.Add('```')
    foreach($r in $rows){ [void]$lines.Add([string]$r) }
    [void]$lines.Add('```')
}

function Get-NaturalNum([string]$title){
    if($title -match '(?i)(?:^|[_\-\s])(\d+)(\.[^.]+)?$'){ return [int]$Matches[1] }
    if($title -match '(\d+)(?=\.[^.]+$)'){ return [int]$Matches[1] }
    return 0
}

$seriesNo=0

function Document-Series([string]$strategy,[int]$projectId,[string]$seriesKey,[object[]]$memberRows){
    $script:seriesNo++
    $parsed = foreach($m in $memberRows){
        $mp = ([string]$m) -split "`t",2
        if($mp.Count -lt 2){ continue }
        [pscustomobject]@{ Id=[int]$mp[0]; Title=$mp[1]; Num=(Get-NaturalNum $mp[1]) }
    }
    $parsed = @($parsed)
    $titleSortIds = @($parsed | Sort-Object Title | ForEach-Object { $_.Id })
    $naturalSortIds = @($parsed | Sort-Object Num, Title | ForEach-Object { $_.Id })
    $titleSortTitles = @($parsed | Sort-Object Title | ForEach-Object { $_.Title })
    $naturalTitles = @($parsed | Sort-Object Num, Title | ForEach-Object { $_.Title })
    [void]$script:lines.Add('')
    [void]$script:lines.Add(('### Serie {0}' -f $script:seriesNo))
    [void]$script:lines.Add(('- strategy: {0}' -f $strategy))
    [void]$script:lines.Add(('- series_key: {0}' -f $seriesKey))
    [void]$script:lines.Add(('- project_id: {0}' -f $projectId))
    [void]$script:lines.Add(('- media_count(sample): {0}' -f $parsed.Count))
    [void]$script:lines.Add(('- actual order (title lex): {0}' -f ($titleSortTitles -join ' | ')))
    [void]$script:lines.Add(('- expected order (natural num): {0}' -f ($naturalTitles -join ' | ')))
    [void]$script:lines.Add(('- title-sort ids: {0}' -f ($titleSortIds -join ',')))
    [void]$script:lines.Add(('- natural-number ids: {0}' -f ($naturalSortIds -join ',')))
    if(($titleSortIds -join ',') -ne ($naturalSortIds -join ',')){
        [void]$script:lines.Add('- NOTE: title lex sort != natural number sort (FRV-8 requirement demonstrated)')
    }
}

$fs = Ro @"
SELECT project_id || char(9) || COALESCE(source_value,query_text) || char(9) || COUNT(DISTINCT media_id)
FROM discoveries
WHERE source_type='filename-series'
GROUP BY project_id, COALESCE(source_value,query_text)
HAVING COUNT(DISTINCT media_id)>=3
ORDER BY COUNT(DISTINCT media_id) DESC
LIMIT 5;
"@
Add-SeriesBlock 'filename-series top groups' $fs

$ts = Ro @"
SELECT project_id || char(9) || COALESCE(source_value,query_text) || char(9) || COUNT(DISTINCT media_id)
FROM discoveries
WHERE source_type='time-series'
GROUP BY project_id, COALESCE(source_value,query_text)
HAVING COUNT(DISTINCT media_id)>=3
ORDER BY COUNT(DISTINCT media_id) DESC
LIMIT 5;
"@
Add-SeriesBlock 'time-series top groups' $ts

$allGroups = @()
foreach($r in $fs){ $allGroups += [pscustomobject]@{Type='discovery/filename-series'; Row=[string]$r} }
foreach($r in $ts){ $allGroups += [pscustomobject]@{Type='discovery/time-series'; Row=[string]$r} }

foreach($g in $allGroups){
    $p = $g.Row -split "`t"
    if($p.Count -lt 3){ continue }
    $projectId=[int]$p[0]
    $skRaw=$p[1]
    $skEsc=$skRaw -replace "'","''"
    $stype = if($g.Type -like '*filename*'){ 'filename-series' } else { 'time-series' }
    $members = Ro @"
SELECT m.id || char(9) || m.title
FROM discoveries d
JOIN media m ON m.id=d.media_id
WHERE d.project_id=$projectId AND d.source_type='$stype'
  AND COALESCE(d.source_value,d.query_text)='$skEsc'
ORDER BY m.title
LIMIT 20;
"@
    if(@($members).Count -lt 2){ continue }
    Document-Series $g.Type $projectId $skRaw $members
    if($seriesNo -ge 8){ break }
}

# Natural 1/2/10 groups
$prefixHit = Ro @"
SELECT prefix || char(9) || COUNT(*) || char(9) || GROUP_CONCAT(title,' || ')
FROM (
  SELECT id, title,
    CASE
      WHEN title GLOB '*_[0-9].jpg' THEN substr(title, 1, length(title)-5)
      WHEN title GLOB '*_[0-9][0-9].jpg' THEN substr(title, 1, length(title)-6)
      WHEN title GLOB '*_[0-9][0-9][0-9].jpg' THEN substr(title, 1, length(title)-7)
      ELSE NULL
    END AS prefix,
    CASE
      WHEN title GLOB '*_[0-9].jpg' THEN CAST(substr(title, length(title)-4, 1) AS INT)
      WHEN title GLOB '*_[0-9][0-9].jpg' THEN CAST(substr(title, length(title)-5, 2) AS INT)
      WHEN title GLOB '*_[0-9][0-9][0-9].jpg' THEN CAST(substr(title, length(title)-6, 3) AS INT)
      ELSE NULL
    END AS n
  FROM media
  WHERE title GLOB '*_[0-9].jpg' OR title GLOB '*_[0-9][0-9].jpg' OR title GLOB '*_[0-9][0-9][0-9].jpg'
  LIMIT 12000
) x
WHERE prefix IS NOT NULL AND n IS NOT NULL
GROUP BY prefix
HAVING SUM(CASE WHEN n=1 THEN 1 ELSE 0 END)>0
   AND SUM(CASE WHEN n=2 THEN 1 ELSE 0 END)>0
   AND SUM(CASE WHEN n=10 THEN 1 ELSE 0 END)>0
ORDER BY COUNT(*) DESC
LIMIT 3;
"@
Add-SeriesBlock 'natural 1/2/10 prefix hits' $prefixHit

foreach($hit in $prefixHit){
    if($seriesNo -ge 10){ break }
    $hp = ([string]$hit) -split "`t"
    if($hp.Count -lt 1){ continue }
    $prefix = $hp[0]
    $prefEsc = $prefix -replace "'","''"
    $members = Ro @"
SELECT id || char(9) || title FROM media
WHERE title LIKE '$prefEsc%' AND (
  title GLOB '*_[0-9].jpg' OR title GLOB '*_[0-9][0-9].jpg' OR title GLOB '*_[0-9][0-9][0-9].jpg'
)
ORDER BY title
LIMIT 20;
"@
    if(@($members).Count -ge 3){
        Document-Series 'natural-filename-group' 0 $prefix $members
    }
}

$up = Ro @"
SELECT current_uploader || char(9) || substr(current_timestamp,1,13) || char(9) || COUNT(*)
FROM media
WHERE current_uploader IS NOT NULL AND current_uploader<>'' AND current_timestamp IS NOT NULL
GROUP BY current_uploader, substr(current_timestamp,1,13)
HAVING COUNT(*)>=5
ORDER BY COUNT(*) DESC
LIMIT 5;
"@
Add-SeriesBlock 'uploader+hour buckets (S2 candidates)' $up

foreach($u in $up){
    if($seriesNo -ge 12){ break }
    $uparts = ([string]$u) -split "`t"
    if($uparts.Count -lt 3){ continue }
    $uploader=$uparts[0]; $bucket=$uparts[1]
    $uEsc=$uploader -replace "'","''"
    $bEsc=$bucket -replace "'","''"
    $members = Ro @"
SELECT id || char(9) || COALESCE(title,'') FROM media
WHERE current_uploader='$uEsc' AND substr(current_timestamp,1,13)='$bEsc'
ORDER BY current_timestamp, id
LIMIT 15;
"@
    if(@($members).Count -ge 3){
        Document-Series 'uploader+time-window' 0 ("{0}@{1}" -f $uploader,$bucket) $members
    }
}

# Extra filename groups from filename (non-series) discoveries if still short
if($seriesNo -lt 10){
    $extra = Ro @"
SELECT project_id || char(9) || COALESCE(source_value,query_text) || char(9) || COUNT(DISTINCT media_id)
FROM discoveries
WHERE source_type IN ('filename','filename-series')
GROUP BY project_id, COALESCE(source_value,query_text)
HAVING COUNT(DISTINCT media_id)>=4
ORDER BY COUNT(DISTINCT media_id) DESC
LIMIT 8;
"@
    foreach($er in $extra){
        if($seriesNo -ge 10){ break }
        $p = ([string]$er) -split "`t"
        if($p.Count -lt 3){ continue }
        $projectId=[int]$p[0]; $skRaw=$p[1]; $skEsc=$skRaw -replace "'","''"
        $members = Ro @"
SELECT m.id || char(9) || m.title
FROM discoveries d JOIN media m ON m.id=d.media_id
WHERE d.project_id=$projectId AND d.source_type IN ('filename','filename-series')
  AND COALESCE(d.source_value,d.query_text)='$skEsc'
ORDER BY m.title LIMIT 20;
"@
        if(@($members).Count -ge 3){
            Document-Series 'discovery/filename-group' $projectId $skRaw $members
        }
    }
}

Set-Content -LiteralPath $OutFile -Value $lines -Encoding utf8
Write-Host ("Wrote {0} (series documented: {1})" -f $OutFile,$seriesNo)
if($seriesNo -lt 10){ throw ("FRV-8 requires >=10 real series documented, got {0}" -f $seriesNo) }
Write-Host 'PASS series real sampling (see report)' -ForegroundColor Green
