# Phase-1 verification for FRV-6..10 on synthetic DB copy.
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $env:TEMP 'findseries-review-phase1-test.db'),
    [string]$SqlitePath,
    [string]$RepoRoot
)
$ErrorActionPreference='Stop'
if(-not $RepoRoot){ $RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
if(-not(Test-Path (Join-Path $RepoRoot 'Tools\sqlite3.exe'))){ throw "repo root not found from $PSScriptRoot (got $RepoRoot)" }
if(-not $SqlitePath){ $SqlitePath=Join-Path $RepoRoot 'Tools\sqlite3.exe' }
$mig=Join-Path $RepoRoot 'review\db\Invoke-ReviewMigrations.ps1'

function Invoke-SqliteChecked([string]$Db,[string]$Sql){
    $out=& $SqlitePath $Db $Sql 2>&1
    if($LASTEXITCODE -ne 0){ throw "sqlite failed: $out" }
    return $out
}

& (Join-Path $PSScriptRoot 'New-Phase1TestDatabase.ps1') -DatabasePath $DatabasePath -SqlitePath $SqlitePath -RepoRoot $RepoRoot

& $mig -DatabasePath $DatabasePath -SqlitePath $SqlitePath -Backup
& $mig -DatabasePath $DatabasePath -SqlitePath $SqlitePath

# FRV-6 mapped provenance >=50
$prov=Invoke-SqliteChecked $DatabasePath @"
SELECT COUNT(DISTINCT d.media_id)
FROM discoveries d
JOIN review_provenance_type_map m ON m.source_type=d.source_type
WHERE d.project_id=14;
"@
Write-Host "FRV-6 mapped media: $prov"
if([int]$prov -lt 50){throw "expected >=50 mapped media, got $prov"}

# Seed semantics: neighbor uses media: parent; keyword uses query
$seedCheck=Invoke-SqliteChecked $DatabasePath @"
SELECT COUNT(*) FROM discoveries d
JOIN review_provenance_type_map m ON m.source_type=d.source_type
WHERE d.project_id=14 AND m.family='neighbor' AND d.parent_media_id IS NOT NULL;
"@
if([int]$seedCheck -lt 1){ throw 'expected neighbor rows with parent_media_id' }

# FRV-7 subtree
$sub=Invoke-SqliteChecked $DatabasePath @"
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

# FRV-8 natural sort + primary unique
$null=Invoke-SqliteChecked $DatabasePath @"
INSERT OR REPLACE INTO media_series_keys(project_id,media_id,strategy,series_key,sequence_no,sequence_label,is_primary,built_at) VALUES
 (7,1,'filename','dental_chair',1,'1',1,'2026-08-14T12:00:00.000Z'),
 (7,2,'filename','dental_chair',2,'2',1,'2026-08-14T12:00:00.000Z'),
 (7,3,'filename','dental_chair',10,'10',1,'2026-08-14T12:00:00.000Z');
"@
$order=((Invoke-SqliteChecked $DatabasePath "SELECT media_id FROM media_series_keys WHERE project_id=7 AND series_key='dental_chair' ORDER BY sequence_no, media_id;") -join ',')
Write-Host "FRV-8 natural order: $order"
if($order -ne '1,2,3'){throw "natural order failed: $order"}
$dupPrimaryFailed=$false
try {
    $null=Invoke-SqliteChecked $DatabasePath "INSERT INTO media_series_keys(project_id,media_id,strategy,series_key,sequence_no,is_primary,built_at) VALUES(7,1,'uploader_time','other',1,1,'2026-08-14T12:00:00.000Z');"
} catch { $dupPrimaryFailed=$true }
if(-not $dupPrimaryFailed){ throw 'expected unique primary violation' }
Write-Host 'FRV-8 primary unique: PASS'

# FRV-9: 100 distinct media embeddings, two models, phash pending without hash
$null=Invoke-SqliteChecked $DatabasePath @"
INSERT OR IGNORE INTO media_embedding_models(model_id,dim,created_at) VALUES
 ('model-a',4,'2026-08-14T12:00:00.000Z'),('model-b',8,'2026-08-14T12:00:00.000Z');
WITH RECURSIVE seq(i) AS (SELECT 10 UNION ALL SELECT i+1 FROM seq WHERE i<109)
INSERT OR IGNORE INTO media_embeddings(media_id,model_id,status,embedding,computed_at)
SELECT i,'model-a','ready',x'00000000','2026-08-14T12:00:00.000Z' FROM seq;
INSERT OR IGNORE INTO media_embeddings(media_id,model_id,status,embedding,computed_at)
VALUES (10,'model-b','ready',x'0000000000000000','2026-08-14T12:00:00.000Z');
INSERT OR IGNORE INTO media_phash(media_id,algorithm,phash,status) VALUES
 (10,'ahash64-v1',NULL,'pending'),
 (11,'ahash64-v1','abcd','ready');
"@
$mix=Invoke-SqliteChecked $DatabasePath "SELECT COUNT(*) FROM media_embeddings WHERE model_id='model-a';"
$b=Invoke-SqliteChecked $DatabasePath "SELECT COUNT(*) FROM media_embeddings WHERE model_id='model-b';"
Write-Host "FRV-9 embeddings model-a=$mix model-b=$b"
if([int]$mix -lt 100){throw 'model-a needs >=100 distinct media'}
if([int]$b -ne 1){throw 'model-b isolation failed'}
$readyBad=$false
try { $null=Invoke-SqliteChecked $DatabasePath "INSERT INTO media_phash(media_id,algorithm,phash,status) VALUES(12,'ahash64-v1',NULL,'ready');" } catch { $readyBad=$true }
if(-not $readyBad){ throw 'ready phash without hash should fail' }

$ic=Invoke-SqliteChecked $DatabasePath 'PRAGMA integrity_check;'
if(($ic -join '') -ne 'ok'){throw "integrity_check failed: $ic"}
Write-Host "PASS Phase-1 FRV-6..10 verification" -ForegroundColor Green
