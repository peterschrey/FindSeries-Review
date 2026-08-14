# Read-only Cat_Dentistry category-graph checks against a real DB.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabasePath,
    [string]$SqlitePath,
    [string]$ProjectSlug = 'cat-dentistry',
    [string]$OutFile
)
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if(-not $SqlitePath){ $SqlitePath=Join-Path $RepoRoot 'Tools\sqlite3.exe' }
if(-not $OutFile){ $OutFile=Join-Path $env:TEMP 'fs-category-graph-real.md' }
$uri="file:$($DatabasePath.Replace('\','/'))?mode=ro"

function Ro([string]$Sql){
    $out=& $SqlitePath $uri '.timeout 180000' $Sql 2>&1
    if($LASTEXITCODE -ne 0){ throw "sqlite failed: $out" }
    return @($out | Where-Object { $_ -and $_.ToString().Trim() -ne '' })
}

$proj = Ro ("SELECT id, name, COALESCE(slug,'') FROM projects WHERE lower(slug)='{0}' LIMIT 1;" -f $ProjectSlug.ToLowerInvariant())
if(-not $proj){ $proj = Ro "SELECT id, name, COALESCE(slug,'') FROM projects WHERE name LIKE 'Cat_Dentistry' ORDER BY id LIMIT 1;" }
$pp = ($proj[0] -split '\|')
$projectId=[int]$pp[0]
$projectName=$pp[1]
Write-Host ("Project {0} {1}" -f $projectId,$projectName)

$depth = Ro ("SELECT depth || '::' || COUNT(*) FROM project_categories WHERE project_id={0} GROUP BY depth ORDER BY depth;" -f $projectId)

# Nodes with real category discoveries (primary probe set), plus dentistry-named and high-fanout.
$hotNodes = Ro @"
SELECT pc.category_id || '::' || c.title || '::' || pc.depth || '::' || pc.child_count || '::' || pc.member_count || '::' || h.c
FROM project_categories pc
JOIN categories c ON c.id=pc.category_id
JOIN (
  SELECT origin_category_id AS id, COUNT(DISTINCT media_id) AS c
  FROM discoveries
  WHERE project_id=$projectId AND source_type='category' AND origin_category_id IS NOT NULL
  GROUP BY origin_category_id
  HAVING c>=20
) h ON h.id=pc.category_id
WHERE pc.project_id=$projectId
ORDER BY pc.depth ASC, h.c DESC
LIMIT 12;
"@
$dentNodes = Ro ("SELECT pc.category_id || '::' || c.title || '::' || pc.depth || '::' || pc.child_count || '::' || pc.member_count FROM project_categories pc JOIN categories c ON c.id=pc.category_id WHERE pc.project_id={0} AND (lower(c.title) LIKE '%dent%' OR lower(c.title) LIKE '%tooth%' OR lower(c.title) LIKE '%oral%' OR lower(c.title) LIKE '%zahn%') ORDER BY pc.child_count DESC, pc.depth DESC LIMIT 8;" -f $projectId)
$parentNodes = Ro @"
SELECT DISTINCT p.category_id || '::' || c.title || '::' || p.depth || '::' || p.child_count || '::' || p.member_count
FROM project_categories leaf
JOIN project_categories p ON p.project_id=leaf.project_id AND p.category_id=leaf.parent_category_id
JOIN categories c ON c.id=p.category_id
WHERE leaf.project_id=$projectId
  AND leaf.category_id IN (
    SELECT origin_category_id FROM discoveries
    WHERE project_id=$projectId AND source_type='category' AND origin_category_id IS NOT NULL
    GROUP BY origin_category_id HAVING COUNT(DISTINCT media_id)>=100
  )
ORDER BY p.child_count DESC
LIMIT 8;
"@
$roots = Ro ("SELECT pc.category_id || '::' || c.title || '::' || pc.depth || '::' || pc.child_count || '::' || pc.member_count FROM project_categories pc JOIN categories c ON c.id=pc.category_id WHERE pc.project_id={0} ORDER BY pc.child_count DESC, pc.member_count DESC LIMIT 8;" -f $projectId)
$oid = Ro ("SELECT SUM(CASE WHEN origin_category_id IS NULL THEN 1 ELSE 0 END) || '::' || SUM(CASE WHEN origin_category_id IS NOT NULL THEN 1 ELSE 0 END) FROM discoveries WHERE project_id={0} AND source_type='category';" -f $projectId)

$lines = New-Object Collections.Generic.List[string]
[void]$lines.Add('# Category graph real verification')
[void]$lines.Add('')
[void]$lines.Add(('DB: {0} (read-only)' -f $DatabasePath))
[void]$lines.Add(('Project: {0} / {1}' -f $projectId,$projectName))
[void]$lines.Add('')
[void]$lines.Add('## Depth histogram (depth::count)')
[void]$lines.Add('```')
foreach($d in $depth){ [void]$lines.Add([string]$d) }
[void]$lines.Add('```')
[void]$lines.Add('## Hot origin_category nodes (with discoveries)')
[void]$lines.Add('```')
foreach($r in $hotNodes){ [void]$lines.Add([string]$r) }
[void]$lines.Add('```')
[void]$lines.Add('## Parent nodes of hot leaves')
[void]$lines.Add('```')
foreach($r in $parentNodes){ [void]$lines.Add([string]$r) }
[void]$lines.Add('```')
[void]$lines.Add('## Dentistry-related nodes (sample)')
[void]$lines.Add('```')
foreach($r in $dentNodes){ [void]$lines.Add([string]$r) }
[void]$lines.Add('```')
[void]$lines.Add('## Top fanout nodes')
[void]$lines.Add('```')
foreach($r in $roots){ [void]$lines.Add([string]$r) }
[void]$lines.Add('```')
$oidParts = (($oid -join '') -split '::')
$nullOid = if($oidParts.Count -ge 1){$oidParts[0]}else{'?'}
$nnOid = if($oidParts.Count -ge 2){$oidParts[1]}else{'?'}
$totalOid = 0
if($nullOid -match '^\d+$' -and $nnOid -match '^\d+$'){ $totalOid = [long]$nullOid + [long]$nnOid }
$pctNull = if($totalOid -gt 0){ [math]::Round(100.0 * [long]$nullOid / $totalOid, 2) } else { 0 }
[void]$lines.Add(('## origin_category_id coverage (null|not-null): {0} | {1}' -f $nullOid,$nnOid))
[void]$lines.Add(('## share category discoveries without origin_category_id: {0}%' -f $pctNull))

# Build probe set: hot + parents + dent + fanout, unique, at least 5
$nodeIds = New-Object 'System.Collections.Generic.List[int]'
$nodeMeta = @{}
foreach($r in @($hotNodes + $parentNodes + $dentNodes + $roots)){
    $parts = ([string]$r) -split '::'
    if($parts.Count -lt 3){ continue }
    $id=[int]$parts[0]
    if($nodeIds.Contains($id)){ continue }
    $nodeIds.Add($id)
    $nodeMeta[$id] = @{ Title=$parts[1]; Depth=[int]$parts[2] }
    if($nodeIds.Count -ge 8){ break }
}

[void]$lines.Add('')
[void]$lines.Add('## Subtree DISTINCT media_id (recursive CTE)')
$cteResults = @{}
foreach($nid in $nodeIds){
    $cnt = Ro @"
WITH RECURSIVE sub AS (
  SELECT category_id AS id, 0 AS d FROM project_categories WHERE project_id=$projectId AND category_id=$nid
  UNION ALL
  SELECT pc.category_id, sub.d+1 FROM project_categories pc JOIN sub ON pc.parent_category_id=sub.id
  WHERE pc.project_id=$projectId AND sub.d<32
)
SELECT COUNT(DISTINCT d.media_id) FROM discoveries d
JOIN sub ON d.origin_category_id=sub.id
WHERE d.project_id=$projectId AND d.source_type='category';
"@
    $exact = Ro ("SELECT COUNT(DISTINCT media_id) FROM discoveries WHERE project_id={0} AND source_type='category' AND origin_category_id={1};" -f $projectId,$nid)
    $cteVal = ($cnt -join '').Trim()
    $exactVal = ($exact -join '').Trim()
    $cteResults[$nid] = $cteVal
    $meta = $nodeMeta[$nid]
    [void]$lines.Add(('- node {0} (depth {1}, {2}): subtree={3} exact-node={4}' -f $nid,$meta.Depth,$meta.Title,$cteVal,$exactVal))
    Write-Host ("node {0} subtree={1} exact={2}" -f $nid,$cteVal,$exactVal)
}

# Independent BFS sample for first node with subtree>0
$probe = ($nodeIds | Where-Object { [long]$cteResults[$_] -gt 0 } | Select-Object -First 1)
if($probe){
    $bfs = Ro @"
WITH RECURSIVE sub AS (
  SELECT category_id AS id, 0 AS d FROM project_categories WHERE project_id=$projectId AND category_id=$probe
  UNION ALL
  SELECT pc.category_id, sub.d+1 FROM project_categories pc JOIN sub ON pc.parent_category_id=sub.id
  WHERE pc.project_id=$projectId AND sub.d<32
),
ids AS (SELECT id FROM sub)
SELECT COUNT(DISTINCT d.media_id) FROM discoveries d
WHERE d.project_id=$projectId AND d.source_type='category'
  AND d.origin_category_id IN (SELECT id FROM ids);
"@
    [void]$lines.Add('')
    [void]$lines.Add(('## Independent SQL plausibility (IN-subquery) for node {0}: {1} (CTE was {2})' -f $probe,($bfs -join ''),$cteResults[$probe]))
    if(($bfs -join '').Trim() -ne [string]$cteResults[$probe]){ throw "CTE vs independent sample mismatch for node $probe" }
}

if($nodeIds.Count -ge 2){
    $pick = @($nodeIds | Select-Object -First 5)
    $inList = ($pick -join ',')
    $union = Ro @"
WITH RECURSIVE sub AS (
  SELECT category_id AS id FROM project_categories WHERE project_id=$projectId AND category_id IN ($inList)
  UNION
  SELECT pc.category_id FROM project_categories pc JOIN sub ON pc.parent_category_id=sub.id WHERE pc.project_id=$projectId
)
SELECT COUNT(DISTINCT d.media_id) FROM discoveries d
JOIN sub ON d.origin_category_id=sub.id
WHERE d.project_id=$projectId AND d.source_type='category';
"@
    [void]$lines.Add('')
    [void]$lines.Add(('## Union of {0} nodes => DISTINCT media_id={1}' -f $pick.Count,($union -join '')))
}

$multi = Ro ("SELECT COUNT(*) FROM (SELECT media_id FROM discoveries WHERE project_id={0} AND source_type='category' AND origin_category_id IS NOT NULL GROUP BY media_id HAVING COUNT(DISTINCT origin_category_id)>1);" -f $projectId)
[void]$lines.Add('')
[void]$lines.Add(('## Media with multiple origin categories: {0}' -f ($multi -join '')))
[void]$lines.Add('')
[void]$lines.Add('Closure table not populated (performance not required for P0).')

if($nodeIds.Count -lt 5){ throw "Need at least 5 probe nodes, got $($nodeIds.Count)" }
$positive = @($nodeIds | Where-Object { [long]$cteResults[$_] -gt 0 })
if($positive.Count -lt 3){ throw "Need at least 3 subtrees with media, got $($positive.Count)" }

Set-Content -LiteralPath $OutFile -Value $lines -Encoding utf8
Write-Host ("Wrote {0}" -f $OutFile)
Write-Host 'PASS category graph real checks (see report)' -ForegroundColor Green
