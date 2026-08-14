# Merge-FsMediaRows review-status integration tests (synthetic DB, never production).
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$WorkDir
)
$ErrorActionPreference='Stop'
if(-not $RepoRoot){ $RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
if(-not $WorkDir){ $WorkDir=Join-Path $env:TEMP 'fs-review-merge-tests' }
$sqlite = Join-Path $RepoRoot 'Tools\sqlite3.exe'
$schemaClean = Join-Path $WorkDir 'schema.sql.clean'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

Import-Module (Join-Path $RepoRoot 'Modules\FindSeries.Database.psm1') -Force

function Invoke-Sql([string]$Db,[string]$Sql){
    $out = & $sqlite $Db $Sql 2>&1
    if($LASTEXITCODE -ne 0){ throw "sqlite failed: $out" }
    return $out
}

function New-BaseDb([string]$Db,[switch]$WithReview){
    Remove-Item $Db,"$Db-wal","$Db-shm" -Force -ErrorAction SilentlyContinue
    if(-not(Test-Path $schemaClean)){
        $raw = Join-Path $WorkDir 'schema.sql'
        if(-not(Test-Path $raw)){
            # Prefer fixture if present; else dump from repo-local tools against empty init via migrations helper schema excerpt.
            throw "Missing $schemaClean - run New-Phase1TestDatabase once or provide schema dump."
        }
        Get-Content $raw | Where-Object { $_ -notmatch 'sqlite_sequence|sqlite_stat1' } | Set-Content $schemaClean -Encoding utf8
    }
    $null = Invoke-Sql $Db ".read `"$($schemaClean.Replace('\','/'))`""
    $null = Invoke-Sql $Db @"
PRAGMA foreign_keys=ON;
PRAGMA journal_mode=WAL;
INSERT OR IGNORE INTO projects(id,name,slug,profile,language,config_json,created_at,updated_at) VALUES
 (1,'P1','p1','t','de','{}',datetime('now'),datetime('now')),
 (2,'P2','p2','t','de','{}',datetime('now'),datetime('now'));
INSERT OR IGNORE INTO media(id,title,created_at,updated_at) VALUES
 (10,'File:Survivor.jpg',datetime('now'),datetime('now')),
 (20,'File:Duplicate.jpg',datetime('now'),datetime('now'));
INSERT OR IGNORE INTO project_media(project_id,media_id,score,selected,download_requested,first_seen_at,updated_at) VALUES
 (1,10,1,1,0,datetime('now'),datetime('now')),
 (1,20,1,1,0,datetime('now'),datetime('now')),
 (2,10,1,1,0,datetime('now'),datetime('now')),
 (2,20,1,1,0,datetime('now'),datetime('now'));
"@
    if($WithReview){
        & (Join-Path $RepoRoot 'review\db\Invoke-ReviewMigrations.ps1') -DatabasePath $Db -SqlitePath $sqlite -SkipIntegrity | Out-Null
    }
}

# Ensure schema dump exists via phase1 helper fixture path or create minimal from migrations Ensure path
$phase1Helper = Join-Path $RepoRoot 'review\db\tests\New-Phase1TestDatabase.ps1'
$defaultDump = Join-Path $RepoRoot 'review\db\fixtures\schema.sql.clean'
if(Test-Path $defaultDump){ Copy-Item $defaultDump $schemaClean -Force }

if(-not(Test-Path $schemaClean)){
    throw "No schema fixture. Place schema.sql.clean under review/db/fixtures/."
}

$pass=0
function Assert-True($cond,$msg){ if(-not $cond){ throw $msg }; $script:pass++ }

# 1) DB without review tables
$db1 = Join-Path $WorkDir 'no-review.db'
New-BaseDb $db1
Assert-True (Merge-FsMediaRows -SqlitePath $sqlite -DatabasePath $db1 -SurvivorId 10 -DuplicateId 20 -Reason 'test') 'merge without review failed'
$left = Invoke-Sql $db1 'SELECT COUNT(*) FROM media WHERE id=20;'
Assert-True ($left -eq '0') 'duplicate should be gone'
$fk = Invoke-Sql $db1 'PRAGMA foreign_key_check;'
Assert-True ([string]::IsNullOrWhiteSpace(($fk -join ''))) "fk check failed: $fk"
Write-Host 'PASS: no-review merge'

function Set-Status($Db,$Project,$Media,$Status,$Batch='b1'){
    Invoke-Sql $Db @"
INSERT INTO media_review_status(project_id,media_id,status,changed_at,source,action,batch_id)
VALUES($Project,$Media,'$Status','2026-08-14T12:00:00.000Z','test','seed','$Batch')
ON CONFLICT(project_id,media_id) DO UPDATE SET status=excluded.status,batch_id=excluded.batch_id;
INSERT INTO media_review_history(project_id,media_id,old_status,new_status,changed_at,source,action,batch_id)
VALUES($Project,$Media,'unreviewed','$Status','2026-08-14T12:00:00.000Z','test','seed','$Batch');
"@ | Out-Null
}

function Get-Status($Db,$Project,$Media){
    $r = Invoke-Sql $Db "SELECT status FROM media_review_status WHERE project_id=$Project AND media_id=$Media;"
    if([string]::IsNullOrWhiteSpace($r)){ return '<missing>' }
    return $r
}

function HistCount($Db){ Invoke-Sql $Db "SELECT COUNT(*) FROM media_review_history;" }

$cases = @(
    @{Name='only-dup'; S=$null; D='reject'; Expect='reject'},
    @{Name='only-surv'; S='keep'; D=$null; Expect='keep'},
    @{Name='same'; S='unsure'; D='unsure'; Expect='unsure'},
    @{Name='surv-keep-dup-reject'; S='keep'; D='reject'; Expect='keep'},
    @{Name='surv-reject-dup-keep'; S='reject'; D='keep'; Expect='keep'},
    @{Name='unsure-reject'; S='unsure'; D='reject'; Expect='unsure'}
)

foreach($c in $cases){
    $db = Join-Path $WorkDir ("case-$($c.Name).db")
    New-BaseDb $db -WithReview
    $h0 = [int](HistCount $db)
    if($c.S){ Set-Status $db 1 10 $c.S }
    if($c.D){ Set-Status $db 1 20 $c.D }
    # second project different statuses
    Set-Status $db 2 10 'reject' 'bp2'
    Set-Status $db 2 20 'keep' 'bp2'
    $h1 = [int](HistCount $db)
    Assert-True (Merge-FsMediaRows -SqlitePath $sqlite -DatabasePath $db -SurvivorId 10 -DuplicateId 20 -Reason 'test') "merge $($c.Name)"
    $got = Get-Status $db 1 10
    Assert-True ($got -eq $c.Expect) "$($c.Name): expected $($c.Expect) got $got"
    $p2 = Get-Status $db 2 10
    Assert-True ($p2 -eq 'keep') "$($c.Name): project2 expected keep got $p2"
    $h2 = [int](HistCount $db)
    Assert-True ($h2 -eq $h1) "$($c.Name): history count changed $h1 -> $h2"
    $dupStatus = Invoke-Sql $db 'SELECT COUNT(*) FROM media_review_status WHERE media_id=20;'
    Assert-True ($dupStatus -eq '0') "$($c.Name): duplicate status rows remain"
    $fk = Invoke-Sql $db 'PRAGMA foreign_key_check;'
    Assert-True ([string]::IsNullOrWhiteSpace(($fk -join ''))) "$($c.Name) fk: $fk"
    Write-Host "PASS: $($c.Name)"
}

# Same-status metadata consistency: newer complete row wins
function Get-StatusMeta([string]$Db,[int]$Project,[int]$Media){
    $r = Invoke-Sql $Db "SELECT status||'|'||changed_at||'|'||COALESCE(source,'')||'|'||COALESCE(action,'')||'|'||COALESCE(batch_id,'') FROM media_review_status WHERE project_id=$Project AND media_id=$Media;"
    return ($r | Select-Object -Last 1)
}

$dbMeta = Join-Path $WorkDir 'case-same-newer-dup.db'
New-BaseDb $dbMeta -WithReview
Invoke-Sql $dbMeta @"
INSERT INTO media_review_status(project_id,media_id,status,changed_at,changed_by,source,action,batch_id)
VALUES(1,10,'keep','2026-01-01T00:00:00.000Z','u','ui','old','batch-old');
INSERT INTO media_review_status(project_id,media_id,status,changed_at,changed_by,source,action,batch_id)
VALUES(1,20,'keep','2026-06-01T00:00:00.000Z','v','api','new','batch-new');
INSERT INTO media_review_history(project_id,media_id,old_status,new_status,changed_at,source,action,batch_id)
VALUES(1,10,'unreviewed','keep','2026-01-01T00:00:00.000Z','ui','old','batch-old'),
      (1,20,'unreviewed','keep','2026-06-01T00:00:00.000Z','api','new','batch-new');
"@ | Out-Null
$hBefore = [int](HistCount $dbMeta)
Assert-True (Merge-FsMediaRows -SqlitePath $sqlite -DatabasePath $dbMeta -SurvivorId 10 -DuplicateId 20 -Reason 'test') 'merge same-newer-dup'
$meta = Get-StatusMeta $dbMeta 1 10
Assert-True ($meta -eq 'keep|2026-06-01T00:00:00.000Z|api|new|batch-new') "same-newer-dup meta: $meta"
Assert-True (([int](HistCount $dbMeta)) -eq $hBefore) 'same-newer-dup history lost'
Write-Host 'PASS: same-newer-dup'

$dbMeta2 = Join-Path $WorkDir 'case-same-newer-surv.db'
New-BaseDb $dbMeta2 -WithReview
Invoke-Sql $dbMeta2 @"
INSERT INTO media_review_status(project_id,media_id,status,changed_at,changed_by,source,action,batch_id)
VALUES(1,10,'reject','2026-07-01T00:00:00.000Z','s','ui','surv','batch-surv');
INSERT INTO media_review_status(project_id,media_id,status,changed_at,changed_by,source,action,batch_id)
VALUES(1,20,'reject','2026-02-01T00:00:00.000Z','d','api','dup','batch-dup');
INSERT INTO media_review_history(project_id,media_id,old_status,new_status,changed_at,source,action,batch_id)
VALUES(1,10,'unreviewed','reject','2026-07-01T00:00:00.000Z','ui','surv','batch-surv'),
      (1,20,'unreviewed','reject','2026-02-01T00:00:00.000Z','api','dup','batch-dup');
"@ | Out-Null
Assert-True (Merge-FsMediaRows -SqlitePath $sqlite -DatabasePath $dbMeta2 -SurvivorId 10 -DuplicateId 20 -Reason 'test') 'merge same-newer-surv'
$meta2 = Get-StatusMeta $dbMeta2 1 10
Assert-True ($meta2 -eq 'reject|2026-07-01T00:00:00.000Z|ui|surv|batch-surv') "same-newer-surv meta: $meta2"
Write-Host 'PASS: same-newer-surv'

Write-Host "PASS Merge review integration ($pass asserts)" -ForegroundColor Green
