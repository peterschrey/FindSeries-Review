# Verifies migration 100 on a schema-only DB copy (never production).
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $env:TEMP 'findseries-review-schema-test.db'),
    [string]$SqlitePath,
    [string]$MigrationPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if (-not $root -or -not (Test-Path (Join-Path $root 'Tools\sqlite3.exe'))) {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
}
if (-not $SqlitePath) { $SqlitePath = Join-Path $root 'Tools\sqlite3.exe' }
if (-not $MigrationPath) { $MigrationPath = Join-Path $root 'review\db\migrations\100_review_status.sql' }

function Invoke-Sql([string]$Db, [string]$Sql) {
    & $SqlitePath $Db $Sql
    if ($LASTEXITCODE -ne 0) { throw "sqlite failed: $Sql" }
}

Write-Host "DB: $DatabasePath" -ForegroundColor Cyan
$before = & $SqlitePath $DatabasePath "SELECT (SELECT COUNT(*) FROM projects),(SELECT COUNT(*) FROM media),(SELECT COUNT(*) FROM project_media),(SELECT COUNT(*) FROM schema_migrations);"
Write-Host "before counts: $before"

$mig = (Get-Content -LiteralPath $MigrationPath -Raw)
# apply twice for idempotency
1..2 | ForEach-Object {
    $tmp = Join-Path $env:TEMP ("fs-mig-100-" + [guid]::NewGuid().ToString('N') + '.sql')
    Set-Content -LiteralPath $tmp -Value $mig -Encoding utf8
    & $SqlitePath $DatabasePath ".read `"$($tmp.Replace('\','/'))`""
    if ($LASTEXITCODE -ne 0) { throw "migration apply failed (pass $_)" }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$after = & $SqlitePath $DatabasePath "SELECT (SELECT COUNT(*) FROM projects),(SELECT COUNT(*) FROM media),(SELECT COUNT(*) FROM project_media),(SELECT COUNT(*) FROM schema_migrations WHERE version=100);"
Write-Host "after counts: $after"
$beforeCore = (($before -split '\|')[0..2] -join '|')
$afterCore = (($after -split '\|')[0..2] -join '|')
if ($beforeCore -cne $afterCore) {
    throw "core table counts changed by migration: $beforeCore -> $afterCore"
}
if (($after -split '\|')[3] -ne '1') { throw 'schema_migrations version 100 missing' }

# set / reset status with protect_keep semantics simulation
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
"@

$states = & $SqlitePath $DatabasePath @"
SELECT pm.media_id, COALESCE(mrs.status,'unreviewed')
FROM project_media pm
LEFT JOIN media_review_status mrs ON mrs.project_id=pm.project_id AND mrs.media_id=pm.media_id
WHERE pm.project_id=7 ORDER BY pm.media_id;
"@
Write-Host "states:`n$states"
$hist = & $SqlitePath $DatabasePath "SELECT COUNT(*) FROM media_review_history WHERE batch_id='$batch';"
if ($hist -ne '2') { throw "expected 2 history rows, got $hist" }

# reset media 2 to unreviewed
Invoke-Sql $DatabasePath @"
BEGIN;
INSERT INTO media_review_history(project_id,media_id,old_status,new_status,changed_at,source,action)
VALUES(7,2,'reject','unreviewed',datetime('now'),'test','hotkey-N');
UPDATE media_review_status SET status='unreviewed', changed_at=datetime('now'), action='hotkey-N', batch_id=NULL
WHERE project_id=7 AND media_id=2;
COMMIT;
"@

$check = & $SqlitePath $DatabasePath "PRAGMA quick_check;"
$wal = & $SqlitePath $DatabasePath "PRAGMA journal_mode;"
$idx = & $SqlitePath $DatabasePath "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'ix_media_review%' ORDER BY name;"
Write-Host "quick_check=$check journal=$wal"
Write-Host "indexes:`n$idx"
if ($check -ne 'ok') { throw "quick_check failed" }
Write-Host "PASS FRV-5 migration verification" -ForegroundColor Green
