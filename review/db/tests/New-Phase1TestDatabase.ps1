# Builds a tiny synthetic DB for Phase-1 verification (never production).
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $env:TEMP 'findseries-review-phase1-test.db'),
    [string]$SqlitePath,
    [string]$SchemaDump
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if(-not $SqlitePath){$SqlitePath=Join-Path $root 'Tools\sqlite3.exe'}
if(-not $SchemaDump){$SchemaDump='C:\Users\pschr\tmp\findseries-review-schema-copy\schema.sql.clean'}
Remove-Item $DatabasePath,"$DatabasePath-wal","$DatabasePath-shm" -Force -ErrorAction SilentlyContinue
if(-not(Test-Path $SchemaDump)){
    $raw='C:\Users\pschr\tmp\findseries-review-schema-copy\schema.sql'
    if(-not(Test-Path $raw)){throw "schema dump missing; run schema export first"}
    Get-Content $raw | Where-Object { $_ -notmatch 'sqlite_sequence|sqlite_stat1' } | Set-Content $SchemaDump -Encoding utf8
}
& $SqlitePath $DatabasePath ".read `"$($SchemaDump.Replace('\','/'))`""
& $SqlitePath $DatabasePath @"
PRAGMA journal_mode=WAL;
INSERT OR IGNORE INTO projects(id,name,slug,profile,language,config_json,created_at,updated_at)
VALUES(7,'Cat_Dentistry','cat-dentistry','test','de','{}',datetime('now'),datetime('now')),
      (14,'Dentist','dentist','test','de','{}',datetime('now'),datetime('now'));
INSERT OR IGNORE INTO categories(id,title,normalized_title,created_at) VALUES
 (100,'Dentistry','dentistry',datetime('now')),
 (101,'Dental chairs','dental chairs',datetime('now')),
 (102,'Dental units','dental units',datetime('now')),
 (103,'Instruments','instruments',datetime('now'));
INSERT OR IGNORE INTO project_categories(project_id,category_id,parent_category_id,depth,status,member_count,file_count,child_count,discovered_at,updated_at) VALUES
 (7,100,NULL,0,'done',3,3,2,datetime('now'),datetime('now')),
 (7,101,100,1,'done',2,2,0,datetime('now'),datetime('now')),
 (7,102,100,1,'done',1,1,1,datetime('now'),datetime('now')),
 (7,103,102,2,'done',1,1,0,datetime('now'),datetime('now'));
INSERT OR IGNORE INTO media(id,title,current_uploader,current_timestamp,created_at,updated_at) VALUES
 (1,'File:Dental_chair_1.jpg','UploaderA','2024-01-01T10:00:00Z',datetime('now'),datetime('now')),
 (2,'File:Dental_chair_2.jpg','UploaderA','2024-01-01T10:05:00Z',datetime('now'),datetime('now')),
 (3,'File:Dental_chair_10.jpg','UploaderA','2024-01-01T10:10:00Z',datetime('now'),datetime('now')),
 (4,'File:Unit_A.jpg','UploaderB','2024-02-01T08:00:00Z',datetime('now'),datetime('now')),
 (5,'File:Instrument_series_01.png','UploaderB','2024-02-01T08:01:00Z',datetime('now'),datetime('now')),
 (6,'File:Instrument_series_02.png','UploaderB','2024-02-01T08:02:00Z',datetime('now'),datetime('now'));
-- 50 provenance sample media ids 10..59
WITH RECURSIVE seq(i) AS (SELECT 10 UNION ALL SELECT i+1 FROM seq WHERE i<59)
INSERT OR IGNORE INTO media(id,title,current_uploader,created_at,updated_at)
SELECT i, 'File:Sample_' || printf('%03d',i) || '.jpg', 'BatchUser', datetime('now'), datetime('now') FROM seq;
INSERT OR IGNORE INTO project_media(project_id,media_id,score,selected,download_requested,first_seen_at,updated_at)
SELECT 7,id,10,1,1,datetime('now'),datetime('now') FROM media;
INSERT OR IGNORE INTO discoveries(project_id,media_id,source_type,source_value,score,query_text,origin_category_id,parent_media_id,created_at) VALUES
 (7,1,'category','Category:Dental chairs',50,NULL,101,NULL,datetime('now')),
 (7,2,'category','Category:Dental chairs',50,NULL,101,NULL,datetime('now')),
 (7,3,'category','Category:Dental chairs',50,NULL,101,NULL,datetime('now')),
 (7,4,'category','Category:Dental units',50,NULL,102,NULL,datetime('now')),
 (7,5,'category','Category:Instruments',50,NULL,103,NULL,datetime('now')),
 (7,6,'category','Category:Instruments',50,NULL,103,NULL,datetime('now')),
 (14,1,'keyword','Zahnarzt',40,'dentist',NULL,NULL,datetime('now')),
 (14,1,'neighbor','seed',30,'dentist',NULL,4,datetime('now')),
 (14,2,'keyword-group','Zahnarzt + Stuhl',40,'dentist + chair',NULL,NULL,datetime('now')),
 (14,3,'filename-series','Dental_chair',20,'Dental_chair',NULL,NULL,datetime('now')),
 (14,5,'time-series','UploaderB|2024-02-01',20,'UploaderB',NULL,NULL,datetime('now')),
 (14,6,'time-series','UploaderB|2024-02-01',20,'UploaderB',NULL,NULL,datetime('now'));
WITH RECURSIVE seq(i) AS (SELECT 10 UNION ALL SELECT i+1 FROM seq WHERE i<59)
INSERT OR IGNORE INTO discoveries(project_id,media_id,source_type,source_value,score,query_text,origin_category_id,created_at)
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
  datetime('now')
FROM seq;
"@
Write-Host "Synthetic DB: $DatabasePath" -ForegroundColor Green
