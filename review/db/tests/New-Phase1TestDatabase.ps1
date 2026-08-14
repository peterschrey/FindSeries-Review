# Builds a tiny synthetic DB for Phase-1 verification (never production).
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $env:TEMP 'findseries-review-phase1-test.db'),
    [string]$SqlitePath,
    [string]$SchemaDump,
    [string]$RepoRoot
)
$ErrorActionPreference='Stop'
if(-not $RepoRoot){ $RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
if(-not $SqlitePath){ $SqlitePath=Join-Path $RepoRoot 'Tools\sqlite3.exe' }
if(-not(Test-Path -LiteralPath $SqlitePath)){ throw "sqlite3 not found: $SqlitePath" }
if(-not $SchemaDump){ $SchemaDump=Join-Path $RepoRoot 'review\db\fixtures\schema.sql.clean' }
if(-not(Test-Path -LiteralPath $SchemaDump)){ throw "schema fixture missing: $SchemaDump" }

Remove-Item $DatabasePath,"$DatabasePath-wal","$DatabasePath-shm" -Force -ErrorAction SilentlyContinue
& $SqlitePath $DatabasePath ".read `"$($SchemaDump.Replace('\','/'))`""
if($LASTEXITCODE -ne 0){ throw "schema import failed" }

& $SqlitePath $DatabasePath @"
PRAGMA journal_mode=WAL;
INSERT OR IGNORE INTO projects(id,name,slug,profile,language,config_json,created_at,updated_at)
VALUES(7,'Cat_Dentistry','cat-dentistry','test','de','{}','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
      (14,'Dentist','dentist','test','de','{}','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z');
INSERT OR IGNORE INTO categories(id,title,normalized_title,created_at) VALUES
 (100,'Dentistry','dentistry','2026-08-14T12:00:00.000Z'),
 (101,'Dental chairs','dental chairs','2026-08-14T12:00:00.000Z'),
 (102,'Dental units','dental units','2026-08-14T12:00:00.000Z'),
 (103,'Instruments','instruments','2026-08-14T12:00:00.000Z');
INSERT OR IGNORE INTO project_categories(project_id,category_id,parent_category_id,depth,status,member_count,file_count,child_count,discovered_at,updated_at) VALUES
 (7,100,NULL,0,'done',3,3,2,'2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (7,101,100,1,'done',2,2,0,'2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (7,102,100,1,'done',1,1,1,'2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (7,103,102,2,'done',1,1,0,'2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z');
INSERT OR IGNORE INTO media(id,title,current_uploader,current_timestamp,created_at,updated_at) VALUES
 (1,'File:Dental_chair_1.jpg','UploaderA','2024-01-01T10:00:00.000Z','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (2,'File:Dental_chair_2.jpg','UploaderA','2024-01-01T10:05:00.000Z','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (3,'File:Dental_chair_10.jpg','UploaderA','2024-01-01T10:10:00.000Z','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (4,'File:Unit_A.jpg','UploaderB','2024-02-01T08:00:00.000Z','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (5,'File:Instrument_series_01.png','UploaderB','2024-02-01T08:01:00.000Z','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z'),
 (6,'File:Instrument_series_02.png','UploaderB','2024-02-01T08:02:00.000Z','2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z');
WITH RECURSIVE seq(i) AS (SELECT 10 UNION ALL SELECT i+1 FROM seq WHERE i<109)
INSERT OR IGNORE INTO media(id,title,current_uploader,created_at,updated_at)
SELECT i, 'File:Sample_' || printf('%03d',i) || '.jpg', 'BatchUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z' FROM seq;
INSERT OR IGNORE INTO project_media(project_id,media_id,score,selected,download_requested,first_seen_at,updated_at)
SELECT 7,id,10,1,1,'2026-08-14T12:00:00.000Z','2026-08-14T12:00:00.000Z' FROM media;
INSERT OR IGNORE INTO discoveries(project_id,media_id,source_type,source_value,score,query_text,origin_category_id,parent_media_id,created_at) VALUES
 (7,1,'category','Category:Dental chairs',50,NULL,101,NULL,'2026-08-14T12:00:00.000Z'),
 (7,2,'category','Category:Dental chairs',50,NULL,101,NULL,'2026-08-14T12:00:00.000Z'),
 (7,3,'category','Category:Dental chairs',50,NULL,101,NULL,'2026-08-14T12:00:00.000Z'),
 (7,4,'category','Category:Dental units',50,NULL,102,NULL,'2026-08-14T12:00:00.000Z'),
 (7,5,'category','Category:Instruments',50,NULL,103,NULL,'2026-08-14T12:00:00.000Z'),
 (7,6,'category','Category:Instruments',50,NULL,103,NULL,'2026-08-14T12:00:00.000Z'),
 (14,1,'keyword','Zahnarzt',40,'dentist',NULL,NULL,'2026-08-14T12:00:00.000Z'),
 (14,1,'neighbor','seed',30,NULL,NULL,4,'2026-08-14T12:00:00.000Z'),
 (14,2,'keyword-group','Zahnarzt + Stuhl',40,'dentist + chair',NULL,NULL,'2026-08-14T12:00:00.000Z'),
 (14,3,'filename-series','Dental_chair',20,'Dental_chair',NULL,NULL,'2026-08-14T12:00:00.000Z'),
 (14,5,'time-series','UploaderB|2024-02-01',20,'UploaderB',NULL,NULL,'2026-08-14T12:00:00.000Z'),
 (14,6,'time-series','UploaderB|2024-02-01',20,'UploaderB',NULL,NULL,'2026-08-14T12:00:00.000Z');
WITH RECURSIVE seq(i) AS (SELECT 10 UNION ALL SELECT i+1 FROM seq WHERE i<109)
INSERT OR IGNORE INTO discoveries(project_id,media_id,source_type,source_value,score,query_text,origin_category_id,parent_media_id,created_at)
SELECT 14, i,
  CASE (i % 5)
    WHEN 0 THEN 'keyword'
    WHEN 1 THEN 'keyword-group'
    WHEN 2 THEN 'neighbor'
    WHEN 3 THEN 'category'
    ELSE 'time-neighbour'
  END,
  'sample-' || i,
  10,
  CASE WHEN (i % 5) IN (0,1) THEN 'seed-query-' || (i/10) ELSE NULL END,
  CASE WHEN (i % 5)=3 THEN 101 ELSE NULL END,
  CASE WHEN (i % 5)=2 THEN 1 ELSE NULL END,
  '2026-08-14T12:00:00.000Z'
FROM seq;
"@
if($LASTEXITCODE -ne 0){ throw 'seed data insert failed' }
Write-Host "Synthetic DB: $DatabasePath" -ForegroundColor Green
