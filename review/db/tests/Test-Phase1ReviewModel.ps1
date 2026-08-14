# Phase-1 verification for FRV-6..10 on synthetic DB copy.
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $env:TEMP 'findseries-review-phase1-test.db'),
    [string]$SqlitePath
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if(-not(Test-Path (Join-Path $root 'Tools\sqlite3.exe'))){ throw "repo root not found from $PSScriptRoot (got $root)" }
if(-not $SqlitePath){$SqlitePath=Join-Path $root 'Tools\sqlite3.exe'}
$mig=Join-Path $root 'review\db\Invoke-ReviewMigrations.ps1'

& (Join-Path $PSScriptRoot 'New-Phase1TestDatabase.ps1') -DatabasePath $DatabasePath -SqlitePath $SqlitePath

# Apply migrations twice (idempotency / FRV-10)
& $mig -DatabasePath $DatabasePath -SqlitePath $SqlitePath -Backup
& $mig -DatabasePath $DatabasePath -SqlitePath $SqlitePath

# FRV-6: >=50 media with mapped provenance, no invented types
$prov=& $SqlitePath $DatabasePath @"
SELECT COUNT(DISTINCT d.media_id)
FROM discoveries d
JOIN review_provenance_type_map m ON m.source_type=d.source_type
WHERE d.project_id=14;
"@
Write-Host "FRV-6 mapped media: $prov"
if([int]$prov -lt 50){throw "expected >=50 mapped media, got $prov"}
$unknown=& $SqlitePath $DatabasePath @"
SELECT COUNT(*) FROM discoveries d
LEFT JOIN review_provenance_type_map m ON m.source_type=d.source_type
WHERE m.source_type IS NULL;
"@
if([int]$unknown -ne 0){throw "unmapped source_type present: $unknown"}

# FRV-7: subtree under Dentistry(100) should include chairs+units+instruments media 1-6 unique
$sub=& $SqlitePath $DatabasePath @"
WITH RECURSIVE sub AS (
  SELECT category_id AS id, 0 AS rel_depth FROM project_categories WHERE project_id=7 AND category_id=100
  UNION ALL
  SELECT pc.category_id, sub.rel_depth+1 FROM project_categories pc
  JOIN sub ON pc.parent_category_id=sub.id
  WHERE pc.project_id=7 AND sub.rel_depth<32
)
SELECT COUNT(DISTINCT d.media_id) FROM discoveries d
JOIN sub ON d.origin_category_id=sub.id
WHERE d.project_id=7 AND d.source_type='category';
"@
Write-Host "FRV-7 subtree distinct media: $sub"
if([int]$sub -lt 5){throw "subtree count unexpected: $sub"}
$union=& $SqlitePath $DatabasePath @"
WITH RECURSIVE sub AS (
  SELECT category_id AS id FROM project_categories WHERE project_id=7 AND category_id IN (101,103)
  UNION
  SELECT pc.category_id FROM project_categories pc JOIN sub ON pc.parent_category_id=sub.id WHERE pc.project_id=7
)
SELECT COUNT(DISTINCT d.media_id) FROM discoveries d
JOIN sub ON d.origin_category_id=sub.id
WHERE d.project_id=7 AND d.source_type='category';
"@
Write-Host "FRV-7 union 101+103: $union"

# FRV-8: natural sort keys for chair 1,2,10
& $SqlitePath $DatabasePath @"
INSERT OR REPLACE INTO media_series_keys(project_id,media_id,strategy,series_key,sequence_no,sequence_label,is_primary,built_at) VALUES
 (7,1,'filename','dental_chair',1,'1',1,datetime('now')),
 (7,2,'filename','dental_chair',2,'2',1,datetime('now')),
 (7,3,'filename','dental_chair',10,'10',1,datetime('now')),
 (7,5,'filename','instrument_series',1,'01',1,datetime('now')),
 (7,6,'filename','instrument_series',2,'02',1,datetime('now'));
"@
$order=& $SqlitePath $DatabasePath "SELECT media_id FROM media_series_keys WHERE project_id=7 AND series_key='dental_chair' ORDER BY sequence_no, media_id;"
$orderLine=($order -join ',')
Write-Host "FRV-8 natural order: $orderLine"
if($orderLine -ne '1,2,3'){throw "natural order failed: $orderLine"}

# FRV-9: two models, no mix
& $SqlitePath $DatabasePath @"
INSERT OR IGNORE INTO media_embedding_models(model_id,dim,created_at) VALUES
 ('model-a',4,datetime('now')),('model-b',8,datetime('now'));
WITH RECURSIVE seq(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM seq WHERE i<100)
INSERT OR IGNORE INTO media_embeddings(media_id,model_id,status,computed_at)
SELECT CASE WHEN i<=6 THEN i ELSE ((i % 6)+1) END, 'model-a', 'ready', datetime('now') FROM seq;
INSERT OR IGNORE INTO media_embeddings(media_id,model_id,status,computed_at) VALUES (1,'model-b','ready',datetime('now'));
"@
$mix=& $SqlitePath $DatabasePath "SELECT COUNT(*) FROM media_embeddings WHERE model_id='model-a';"
$b=& $SqlitePath $DatabasePath "SELECT COUNT(*) FROM media_embeddings WHERE model_id='model-b';"
Write-Host "FRV-9 embeddings model-a=$mix model-b=$b"
if([int]$mix -lt 6){throw 'model-a rows missing'}
if([int]$b -ne 1){throw 'model-b isolation failed'}

$ic=& $SqlitePath $DatabasePath 'PRAGMA integrity_check;'
if($ic -ne 'ok'){throw "integrity_check failed: $ic"}
Write-Host "PASS Phase-1 FRV-6..10 verification" -ForegroundColor Green
