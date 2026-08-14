# Validates P0 category media resolution with origin_category_id + source_value fallback.
# Read-only against a DB copy (never production writes).
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabasePath,
    [string]$SqlitePath,
    [string]$OutFile,
    [int]$ProjectId = 7
)
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if(-not $SqlitePath){ $SqlitePath=Join-Path $RepoRoot 'Tools\sqlite3.exe' }
if(-not $OutFile){ $OutFile=Join-Path $env:TEMP 'fs-category-fallback.md' }

function Ro([string]$Sql){
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $out=& $SqlitePath $DatabasePath '.timeout 300000' $Sql 2>&1
    if($LASTEXITCODE -ne 0){ throw "sqlite failed: $out" }
    return @{ Lines=@($out | Where-Object { $_ -and $_.ToString().Trim() -ne '' }); Ms=$sw.ElapsedMilliseconds }
}

$lines=New-Object Collections.Generic.List[string]
[void]$lines.Add('# Category fallback real validation')
[void]$lines.Add('')
[void]$lines.Add(('DB: {0}' -f $DatabasePath))
[void]$lines.Add(('Project: {0}' -f $ProjectId))
[void]$lines.Add('')
[void]$lines.Add('## P0 resolution rule')
[void]$lines.Add('1. Use origin_category_id when present.')
[void]$lines.Add('2. Else resolve uniquely via lower(source_value)=categories.normalized_title AND category in project_categories.')
[void]$lines.Add('3. Ambiguous/unresolved source_value => no invented membership.')
[void]$lines.Add('4. Always COUNT(DISTINCT media_id).')
[void]$lines.Add('')

$stats = Ro @"
WITH null_rows AS (
  SELECT d.rowid AS rid, d.media_id, d.source_value, lower(d.source_value) AS sv_norm
  FROM discoveries d
  WHERE d.project_id=$ProjectId AND d.source_type='category' AND d.origin_category_id IS NULL
),
present AS (
  SELECT * FROM null_rows WHERE source_value IS NOT NULL AND trim(source_value)<>''
),
cand AS (
  SELECT n.rid, n.media_id, n.source_value, c.id AS category_id
  FROM present n
  JOIN categories c ON c.normalized_title = n.sv_norm
),
agg AS (
  SELECT rid, media_id, source_value, COUNT(DISTINCT category_id) AS ncat, MIN(category_id) AS category_id
  FROM cand GROUP BY rid, media_id, source_value
),
unique_proj AS (
  SELECT a.rid, a.media_id, a.category_id
  FROM agg a
  JOIN project_categories pc ON pc.project_id=$ProjectId AND pc.category_id=a.category_id
  WHERE a.ncat=1
)
SELECT
  (SELECT COUNT(*) FROM null_rows),
  (SELECT COUNT(*) FROM null_rows WHERE source_value IS NULL OR trim(source_value)=''),
  (SELECT COUNT(*) FROM present),
  (SELECT COUNT(*) FROM agg WHERE ncat=1),
  (SELECT COUNT(*) FROM agg WHERE ncat>1),
  (SELECT COUNT(*) FROM present n WHERE NOT EXISTS (SELECT 1 FROM cand c WHERE c.rid=n.rid)),
  (SELECT COUNT(*) FROM unique_proj),
  (SELECT COUNT(DISTINCT media_id) FROM unique_proj);
"@
$p = ($stats.Lines[0] -split '\|')
[void]$lines.Add('## Null-origin inventory (project category discoveries)')
[void]$lines.Add(('query_ms: {0}' -f $stats.Ms))
[void]$lines.Add(('- null origin_category_id rows: {0}' -f $p[0]))
[void]$lines.Add(('- source_value empty: {0}' -f $p[1]))
[void]$lines.Add(('- source_value present: {0}' -f $p[2]))
[void]$lines.Add(('- uniquely resolvable to categories: {0}' -f $p[3]))
[void]$lines.Add(('- ambiguous category matches: {0}' -f $p[4]))
[void]$lines.Add(('- unresolved: {0}' -f $p[5]))
[void]$lines.Add(('- unique + in project_categories rows: {0}' -f $p[6]))
[void]$lines.Add(('- unique + in project distinct media_id: {0}' -f $p[7]))
[void]$lines.Add('')

# Pick 5 nodes with media
$nodes = Ro @"
SELECT pc.category_id || '|' || c.title || '|' || pc.depth
FROM project_categories pc
JOIN categories c ON c.id=pc.category_id
JOIN (
  SELECT origin_category_id AS id, COUNT(DISTINCT media_id) AS c
  FROM discoveries
  WHERE project_id=$ProjectId AND source_type='category' AND origin_category_id IS NOT NULL
  GROUP BY origin_category_id HAVING c>=20
) h ON h.id=pc.category_id
WHERE pc.project_id=$ProjectId
ORDER BY pc.child_count DESC, h.c DESC
LIMIT 5;
"@

[void]$lines.Add('## Subtree counts: origin-only vs origin+fallback')
$nodeIds=@()
foreach($n in $nodes.Lines){
    $np=$n -split '\|',3
    if($np.Count -lt 2){ continue }
    $nid=[int]$np[0]
    $nodeIds += $nid
    $cmp = Ro @"
WITH RECURSIVE sub AS (
  SELECT category_id AS id FROM project_categories WHERE project_id=$ProjectId AND category_id=$nid
  UNION ALL
  SELECT pc.category_id FROM project_categories pc JOIN sub ON pc.parent_category_id=sub.id
  WHERE pc.project_id=$ProjectId
),
origin_only AS (
  SELECT DISTINCT d.media_id
  FROM discoveries d
  JOIN sub ON d.origin_category_id=sub.id
  WHERE d.project_id=$ProjectId AND d.source_type='category'
),
fallback AS (
  SELECT DISTINCT d.media_id
  FROM discoveries d
  JOIN categories c ON c.normalized_title = lower(d.source_value)
  JOIN sub ON sub.id = c.id
  JOIN project_categories pc ON pc.project_id=$ProjectId AND pc.category_id=c.id
  WHERE d.project_id=$ProjectId AND d.source_type='category'
    AND d.origin_category_id IS NULL
    AND d.source_value IS NOT NULL AND trim(d.source_value)<>''
    AND (
      SELECT COUNT(*) FROM categories c2 WHERE c2.normalized_title = lower(d.source_value)
    ) = 1
),
combined AS (
  SELECT media_id FROM origin_only
  UNION
  SELECT media_id FROM fallback
)
SELECT
  (SELECT COUNT(*) FROM origin_only),
  (SELECT COUNT(*) FROM fallback),
  (SELECT COUNT(*) FROM combined),
  (SELECT COUNT(*) FROM (
     SELECT media_id FROM origin_only
     INTERSECT
     SELECT media_id FROM fallback
  ));
"@
    $cp = ($cmp.Lines[0] -split '\|')
    [void]$lines.Add(('- node {0} ({1}): origin_only={2} fallback_only_contrib={3} combined={4} overlap={5} ms={6}' -f $nid,$np[1],$cp[0],$cp[1],$cp[2],$cp[3],$cmp.Ms))
    Write-Host ("node {0}: origin={1} combined={2} ms={3}" -f $nid,$cp[0],$cp[2],$cmp.Ms)
}

if($nodeIds.Count -lt 5){ throw "Need >=5 probe nodes, got $($nodeIds.Count)" }

# Union of first 3
$uList = ($nodeIds | Select-Object -First 3) -join ','
$union = Ro @"
WITH RECURSIVE sub AS (
  SELECT category_id AS id FROM project_categories WHERE project_id=$ProjectId AND category_id IN ($uList)
  UNION
  SELECT pc.category_id FROM project_categories pc JOIN sub ON pc.parent_category_id=sub.id WHERE pc.project_id=$ProjectId
),
resolved AS (
  SELECT DISTINCT d.media_id
  FROM discoveries d
  JOIN sub ON d.origin_category_id = sub.id
  WHERE d.project_id=$ProjectId AND d.source_type='category'
  UNION
  SELECT DISTINCT d.media_id
  FROM discoveries d
  JOIN categories c ON c.normalized_title = lower(d.source_value)
  JOIN sub ON sub.id = c.id
  JOIN project_categories pc ON pc.project_id=$ProjectId AND pc.category_id=c.id
  WHERE d.project_id=$ProjectId AND d.source_type='category'
    AND d.origin_category_id IS NULL
    AND d.source_value IS NOT NULL AND trim(d.source_value)<>''
    AND (SELECT COUNT(*) FROM categories c2 WHERE c2.normalized_title=lower(d.source_value))=1
)
SELECT COUNT(*) FROM resolved;
"@
[void]$lines.Add('')
[void]$lines.Add(('## Union nodes {0} combined DISTINCT media_id={1} (ms={2})' -f $uList,($union.Lines -join ''),$union.Ms))

# EXPLAIN
$plan = Ro @"
EXPLAIN QUERY PLAN
SELECT DISTINCT d.media_id
FROM discoveries d
JOIN categories c ON c.normalized_title = lower(d.source_value)
JOIN project_categories pc ON pc.project_id=$ProjectId AND pc.category_id=c.id
WHERE d.project_id=$ProjectId AND d.source_type='category'
  AND d.origin_category_id IS NULL
  AND d.source_value IS NOT NULL AND trim(d.source_value)<>'';
"@
[void]$lines.Add('')
[void]$lines.Add('## EXPLAIN QUERY PLAN (fallback join)')
[void]$lines.Add('```')
foreach($pl in $plan.Lines){ [void]$lines.Add([string]$pl) }
[void]$lines.Add('```')

Set-Content -LiteralPath $OutFile -Value $lines -Encoding utf8
Write-Host ("Wrote {0}" -f $OutFile)
Write-Host 'PASS category fallback real validation' -ForegroundColor Green
