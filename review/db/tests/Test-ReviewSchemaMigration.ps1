# Verifies migration 100 on a schema-only DB copy (never production).
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $env:TEMP 'findseries-review-schema-test.db'),
    [string]$SqlitePath,
    [string]$MigrationPath
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $SqlitePath) { $SqlitePath = Join-Path $root 'Tools\sqlite3.exe' }
if (-not $MigrationPath) { $MigrationPath = Join-Path $root 'review\db\migrations\100_review_status.sql' }

# Always rebuild a portable fixture DB (no hardcoded user paths).
& (Join-Path $PSScriptRoot 'New-Phase1TestDatabase.ps1') -DatabasePath $DatabasePath -SqlitePath $SqlitePath -RepoRoot $root

function Invoke-Sql([string]$Db, [string]$Sql) {
    $out = & $SqlitePath $Db $Sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlite failed: $Sql :: $out" }
    return $out
}

Write-Host "DB: $DatabasePath" -ForegroundColor Cyan
$before = Invoke-Sql $DatabasePath "SELECT (SELECT COUNT(*) FROM projects),(SELECT COUNT(*) FROM media),(SELECT COUNT(*) FROM project_media),(SELECT COUNT(*) FROM schema_migrations);"
Write-Host "before counts: $before"

# Apply only migration 100 twice for FRV-5 idempotency
1..2 | ForEach-Object {
    $null = Invoke-Sql $DatabasePath ".read `"$($MigrationPath.Replace('\','/'))`""
}

$after = Invoke-Sql $DatabasePath "SELECT (SELECT COUNT(*) FROM projects),(SELECT COUNT(*) FROM media),(SELECT COUNT(*) FROM project_media),(SELECT COUNT(*) FROM schema_migrations WHERE version=100);"
Write-Host "after counts: $after"
$beforeCore = (($before -split '\|')[0..2] -join '|')
$afterCore = (($after -split '\|')[0..2] -join '|')
if ($beforeCore -cne $afterCore) {
    throw "core table counts changed by migration: $beforeCore -> $afterCore"
}
if (($after -split '\|')[3] -ne '1') { throw 'schema_migrations version 100 missing' }

$batch = [guid]::NewGuid().ToString('N')
Invoke-Sql $DatabasePath @"
BEGIN IMMEDIATE;
INSERT INTO media_review_batches(batch_id,project_id,action,target_status,protect_keep,media_count,changed_count,protected_count,created_at,source)
VALUES('$batch',7,'bulk-reject','reject',1,3,2,1,datetime('now'),'test');
INSERT INTO media_review_status(project_id,media_id,status,changed_at,source,action,batch_id)
VALUES(7,1,'keep',datetime('now'),'test','seed',NULL);
INSERT INTO media_review_history(project_id,media_id,old_status,new_status,changed_at,source,action,batch_id)
SELECT 7,2,'unreviewed','reject',datetime('now'),'test','bulk-reject','$batch'
UNION ALL SELECT 7,3,'unreviewed','reject',datetime('now'),'test','bulk-reject','$batch';
INSERT INTO media_review_status(project_id,media_id,status,changed_at,source,action,batch_id)
VALUES(7,2,'reject',datetime('now'),'test','bulk-reject','$batch'),
      (7,3,'reject',datetime('now'),'test','bulk-reject','$batch');
COMMIT;
"@ | Out-Null

$states = Invoke-Sql $DatabasePath @"
SELECT pm.media_id, COALESCE(mrs.status,'unreviewed')
FROM project_media pm
LEFT JOIN media_review_status mrs ON mrs.project_id=pm.project_id AND mrs.media_id=pm.media_id
WHERE pm.project_id=7 ORDER BY pm.media_id LIMIT 10;
"@
Write-Host "states:`n$states"
$hist = Invoke-Sql $DatabasePath "SELECT COUNT(*) FROM media_review_history WHERE batch_id='$batch';"
if (($hist | Select-Object -Last 1) -ne '2') { throw "expected 2 history rows, got $hist" }

# Preferred sparse reset: history + DELETE current row
Invoke-Sql $DatabasePath @"
BEGIN;
INSERT INTO media_review_history(project_id,media_id,old_status,new_status,changed_at,source,action)
VALUES(7,2,'reject','unreviewed',datetime('now'),'test','hotkey-N');
DELETE FROM media_review_status WHERE project_id=7 AND media_id=2;
COMMIT;
"@ | Out-Null

$sparse = Invoke-Sql $DatabasePath "SELECT COALESCE((SELECT status FROM media_review_status WHERE project_id=7 AND media_id=2),'unreviewed');"
if (($sparse | Select-Object -Last 1) -ne 'unreviewed') { throw "sparse reset failed: $sparse" }

$check = Invoke-Sql $DatabasePath "PRAGMA quick_check;"
$wal = Invoke-Sql $DatabasePath "PRAGMA journal_mode;"
$idx = Invoke-Sql $DatabasePath "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'ix_media_review%' ORDER BY name;"
Write-Host "quick_check=$check journal=$wal"
Write-Host "indexes:`n$idx"
if (($check | Select-Object -Last 1) -ne 'ok') { throw "quick_check failed" }
Write-Host "PASS FRV-5 migration verification" -ForegroundColor Green
