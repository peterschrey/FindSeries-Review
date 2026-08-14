# Read-only provenance sample against a real FindSeries DB (never writes).
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabasePath,
    [string]$SqlitePath,
    [string]$RepoRoot,
    [int]$ProjectId = 14,
    [int]$SampleSize = 50,
    [string]$OutCsv
)
$ErrorActionPreference='Stop'
if(-not $RepoRoot){ $RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
if(-not $SqlitePath){ $SqlitePath=Join-Path $RepoRoot 'Tools\sqlite3.exe' }
if(-not(Test-Path -LiteralPath $DatabasePath)){ throw "DB not found: $DatabasePath" }
if(-not $OutCsv){ $OutCsv=Join-Path $env:TEMP 'fs-provenance-sample.csv' }

$uri = "file:$($DatabasePath.Replace('\','/'))?mode=ro"
$typeMap = @{
  'category'='category'; 'keyword'='keyword'; 'keyword-group'='keyword'; 'keyword-title'='keyword'
  'keyword-group-description'='keyword'; 'keyword-group-filename'='keyword'; 'depicts-search'='keyword'
  'neighbor'='neighbor'; 'time-neighbour'='neighbor'; 'uploader-neighbour'='neighbor'
  'time-series'='series'; 'filename-series'='series'; 'filename'='series'
}

function Invoke-Ro([string]$Sql){
    $out = & $SqlitePath $uri '.timeout 180000' $Sql 2>&1
    if($LASTEXITCODE -ne 0){ throw "sqlite failed: $out" }
    return @($out | Where-Object { $_ -and $_.ToString().Trim() -ne '' })
}

$exists = Invoke-Ro "SELECT id FROM projects WHERE id=$ProjectId LIMIT 1;"
if(-not $exists){
    $pick = Invoke-Ro "SELECT project_id FROM discoveries GROUP BY project_id HAVING COUNT(DISTINCT source_type)>1 ORDER BY COUNT(*) DESC LIMIT 1;"
    if(-not $pick){ throw 'no suitable project' }
    $ProjectId = [int]$pick[0]
}
Write-Host ("Using project_id={0}" -f $ProjectId)

# Two-step: media ids then details (avoids heavy correlated ORDER BY)
$mediaIds = Invoke-Ro @"
SELECT media_id FROM discoveries
WHERE project_id=$ProjectId
GROUP BY media_id
ORDER BY COUNT(*) DESC
LIMIT $SampleSize;
"@
if($mediaIds.Count -lt $SampleSize){ throw ("expected >={0} media, got {1}" -f $SampleSize,$mediaIds.Count) }
$idList = ($mediaIds | ForEach-Object { [int]$_ }) -join ','

$rows = Invoke-Ro @"
SELECT d.media_id, d.source_type,
       COALESCE(d.source_value,''),
       COALESCE(d.query_text,''),
       COALESCE(CAST(d.origin_category_id AS TEXT),''),
       COALESCE(CAST(d.parent_media_id AS TEXT),'')
FROM discoveries d
WHERE d.project_id=$ProjectId AND d.media_id IN ($idList)
ORDER BY d.media_id, d.source_type;
"@

$media = New-Object 'System.Collections.Generic.HashSet[int]'
$unknown = New-Object Collections.Generic.List[string]
$byMedia = @{}
$csv = New-Object Collections.Generic.List[string]
[void]$csv.Add('media_id,source_type,family,source_value,query_text,origin_category_id,parent_media_id,seed_kind,seed_key')

foreach($line in $rows){
    $p = ($line.ToString()) -split '\|',6
    if($p.Count -lt 6){ continue }
    $mid=[int]$p[0]; $st=$p[1]; $sv=$p[2]; $qt=$p[3]; $oid=$p[4]; $parentMediaId=$p[5]
    [void]$media.Add($mid)
    if($typeMap.ContainsKey($st)){
        $family = $typeMap[$st]
    } else {
        $family = 'unknown'
        [void]$unknown.Add($st)
    }
    if(-not $byMedia.ContainsKey($mid)){ $byMedia[$mid]=New-Object 'System.Collections.Generic.HashSet[string]' }
    [void]$byMedia[$mid].Add($family)

    $seedKind=''; $seedKey=''
    if($family -eq 'neighbor' -and $parentMediaId -ne ''){ $seedKind='media'; $seedKey=('media:{0}' -f $parentMediaId) }
    elseif($family -eq 'keyword' -and -not [string]::IsNullOrWhiteSpace($qt)){ $seedKind='query'; $seedKey=$qt.Trim().ToLowerInvariant() }

    [void]$csv.Add(('{0},{1},{2},"{3}","{4}",{5},{6},{7},{8}' -f $mid,$st,$family,($sv -replace '"','""'),($qt -replace '"','""'),$oid,$parentMediaId,$seedKind,$seedKey))
}

$multi=0
foreach($k in $byMedia.Keys){ if($byMedia[$k].Count -gt 1){ $multi++ } }
Set-Content -LiteralPath $OutCsv -Value $csv -Encoding utf8
Write-Host ("Sampled media: {0}" -f $media.Count)
Write-Host ("Multi-family media: {0}" -f $multi)
Write-Host ("Unknown source_types: {0}" -f (((@($unknown) | Select-Object -Unique) -join ', ')))
Write-Host ("CSV: {0}" -f $OutCsv)
if($media.Count -lt $SampleSize){ throw ("expected >={0} media, got {1}" -f $SampleSize,$media.Count) }
Write-Host 'PASS provenance real sample' -ForegroundColor Green
