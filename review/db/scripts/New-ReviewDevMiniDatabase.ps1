<#
.SYNOPSIS
  Build a small representative Review development SQLite DB from a TEST copy.

.DESCRIPTION
  Creates C:\Temp\FindSeries-Review-Test\review-dev-mini.db (~5k–10k media)
  with stratified sampling (NOT first-N IDs). Never touches the production DB.

.PARAMETER SourceDatabase
  Read-only test/gate copy (default: phase1-gate under Temp).

.PARAMETER OutputDatabase
  Destination path (default: review-dev-mini.db).

.PARAMETER TargetMediaCount
  Soft target for distinct media rows (default 8000, clamped 5000–10000).
#>
[CmdletBinding()]
param(
    [string]$SourceDatabase = 'C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db',
    [string]$OutputDatabase = 'C:\Temp\FindSeries-Review-Test\review-dev-mini.db',
    [int]$TargetMediaCount = 8000,
    [string]$SqlitePath,
    [string]$RepoRoot,
    [switch]$SkipVacuum
)
$ErrorActionPreference = 'Stop'

if ($TargetMediaCount -lt 5000) { $TargetMediaCount = 5000 }
if ($TargetMediaCount -gt 10000) { $TargetMediaCount = 10000 }

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}
if (-not $SqlitePath) {
    $SqlitePath = Join-Path $RepoRoot 'Tools\sqlite3.exe'
}
if (-not (Test-Path -LiteralPath $SqlitePath)) {
    throw "sqlite3 not found: $SqlitePath"
}
if (-not (Test-Path -LiteralPath $SourceDatabase)) {
    throw "Source test DB not found: $SourceDatabase (never use production path)"
}

# Hard safety: refuse known production path patterns
$srcFull = [IO.Path]::GetFullPath($SourceDatabase)
if ($srcFull -match '(?i)\\FindSeriesV5-Workspace\\findseries-v5\.db$') {
    throw "Refusing to read production workspace DB as source: $srcFull"
}
if ($srcFull -notmatch '(?i)Temp|test|copy|gate|mini|bench') {
    Write-Warning "Source path does not look like a Temp/test copy: $srcFull"
}

function Invoke-Sqlite {
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Sql,
        [switch]$Readonly
    )
    $args = @()
    if ($Readonly) { $args += '-readonly' }
    $args += @($Database, $Sql)
    $out = & $SqlitePath @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("sqlite failed (exit {0}): {1}`nSQL excerpt: {2}" -f $LASTEXITCODE, ($out | Out-String), $Sql.Substring(0, [Math]::Min(200, $Sql.Length)))
    }
    return $out
}

function Get-DbCount([string]$Database, [string]$Table) {
    $r = (Invoke-Sqlite -Database $Database -Sql "SELECT COUNT(*) FROM `"$Table`";" -Readonly | Out-String).Trim()
    return [long]$r
}

$outDir = Split-Path -Parent $OutputDatabase
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Write-Host "=== New-ReviewDevMiniDatabase ===" -ForegroundColor Cyan
Write-Host "Source : $SourceDatabase"
Write-Host "Output : $OutputDatabase"
Write-Host "Target : $TargetMediaCount media"

$srcSize = (Get-Item -LiteralPath $SourceDatabase).Length
Write-Host ("Source size: {0:N2} GB" -f ($srcSize / 1GB))

Write-Host "Collecting source counts..."
$beforeCounts = [ordered]@{
    projects              = (Get-DbCount $SourceDatabase 'projects')
    media                 = (Get-DbCount $SourceDatabase 'media')
    project_media         = (Get-DbCount $SourceDatabase 'project_media')
    discoveries           = (Get-DbCount $SourceDatabase 'discoveries')
    downloads             = (Get-DbCount $SourceDatabase 'downloads')
    categories            = (Get-DbCount $SourceDatabase 'categories')
    project_categories    = (Get-DbCount $SourceDatabase 'project_categories')
    media_review_status   = (Get-DbCount $SourceDatabase 'media_review_status')
    media_review_history  = (Get-DbCount $SourceDatabase 'media_review_history')
    media_review_batches  = (Get-DbCount $SourceDatabase 'media_review_batches')
    media_series_keys     = (Get-DbCount $SourceDatabase 'media_series_keys')
    review_provenance_type_map = (Get-DbCount $SourceDatabase 'review_provenance_type_map')
}
$beforeCounts.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-28} {1,12:N0}" -f $_.Key, $_.Value) }

# Working DB on same volume as output for ATTACH speed
$workDb = Join-Path $outDir ("review-dev-mini-work-{0}.db" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
Remove-Item -LiteralPath $workDb, "$workDb-wal", "$workDb-shm", $OutputDatabase, "$OutputDatabase-wal", "$OutputDatabase-shm" -Force -ErrorAction SilentlyContinue

Write-Host "Copying schema..."
$schemaFile = Join-Path $outDir ("review-dev-mini-schema-{0}.sql" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $schema = & $SqlitePath -readonly $SourceDatabase '.schema' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "schema dump failed: $schema" }
    # Drop sqlite internal / stats that may conflict; keep review + core tables
    $filtered = ($schema | Out-String) -split "`r?`n" | Where-Object {
        $_ -notmatch '(?i)^CREATE TABLE sqlite_' -and
        $_ -notmatch '(?i)^CREATE INDEX sqlite_' -and
        $_ -notmatch '(?i)sqlite_stat'
    }
    Set-Content -LiteralPath $schemaFile -Value ($filtered -join "`n") -Encoding UTF8
    Invoke-Sqlite -Database $workDb -Sql ".read `"$($schemaFile.Replace('\','/'))`""
} finally {
    Remove-Item -LiteralPath $schemaFile -Force -ErrorAction SilentlyContinue
}

$srcUri = $SourceDatabase.Replace('\', '/')
$target = $TargetMediaCount

Write-Host "Selecting representative media set + copying rows (this may take several minutes)..."
$buildSql = @"
PRAGMA foreign_keys=OFF;
PRAGMA journal_mode=OFF;
PRAGMA synchronous=OFF;
PRAGMA temp_store=MEMORY;
ATTACH DATABASE '$srcUri' AS src;

CREATE TABLE keep_media (
  media_id INTEGER PRIMARY KEY,
  reason TEXT NOT NULL
);

-- 1) Consecutive media_id run for seek/range tests (not first-N: offset into p7)
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT media_id, 'range_p7'
FROM src.project_media
WHERE project_id = 7
  AND media_id >= (
    SELECT media_id FROM src.project_media
    WHERE project_id = 7
    ORDER BY media_id
    LIMIT 1 OFFSET 42000
  )
ORDER BY media_id
LIMIT 800;

-- 2) Deep category branches in Cat_Dentistry (project 7): several deep leaves + ancestors' media
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT d.media_id, 'deep_cat_origin'
FROM src.discoveries d
WHERE d.project_id = 7
  AND d.source_type = 'category'
  AND d.origin_category_id IN (
    SELECT category_id FROM src.project_categories
    WHERE project_id = 7 AND depth >= 2
    ORDER BY member_count DESC
    LIMIT 12
  )
ORDER BY d.media_id
LIMIT 1200;

-- 3) Category fallback-only (null origin_category_id + unique source_value)
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT d.media_id, 'cat_fallback'
FROM src.discoveries d
JOIN src.categories c ON c.normalized_title = lower(d.source_value)
JOIN src.project_categories pc ON pc.project_id = 7 AND pc.category_id = c.id
WHERE d.project_id = 7
  AND d.source_type = 'category'
  AND d.origin_category_id IS NULL
  AND d.source_value IS NOT NULL AND trim(d.source_value) <> ''
  AND (
    SELECT COUNT(*) FROM src.categories c2
    WHERE c2.normalized_title = lower(d.source_value)
  ) = 1
ORDER BY d.media_id
LIMIT 600;

-- 4) Multi-provenance media (project 14 / 9 / 16)
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT media_id, 'multi_provenance'
FROM (
  SELECT media_id, COUNT(DISTINCT source_type) AS ntypes
  FROM src.discoveries
  WHERE project_id IN (9, 14, 16)
  GROUP BY media_id
  HAVING ntypes >= 2
  ORDER BY ntypes DESC, media_id
  LIMIT 1000
);

-- 5) Series: at least 10 series keys, take members
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT d.media_id, 'series'
FROM src.discoveries d
WHERE d.project_id IN (9, 14, 16)
  AND d.source_type IN ('filename-series', 'time-series', 'filename')
  AND COALESCE(d.source_value, d.query_text) IN (
    SELECT sk FROM (
      SELECT COALESCE(source_value, query_text) AS sk, COUNT(DISTINCT media_id) AS n
      FROM src.discoveries
      WHERE project_id IN (9, 14, 16)
        AND source_type IN ('filename-series', 'time-series', 'filename')
        AND COALESCE(source_value, query_text) IS NOT NULL
        AND trim(COALESCE(source_value, query_text)) <> ''
      GROUP BY sk
      HAVING n >= 2
      ORDER BY n DESC
      LIMIT 15
    )
  )
LIMIT 800;

-- 6) Seeds: parents + children for >=5 seeds
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT parent_media_id, 'seed_parent'
FROM (
  SELECT parent_media_id, COUNT(*) AS n
  FROM src.discoveries
  WHERE parent_media_id IS NOT NULL
  GROUP BY parent_media_id
  HAVING n >= 3
  ORDER BY n DESC
  LIMIT 8
);

INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT media_id, 'seed_child'
FROM src.discoveries
WHERE parent_media_id IN (SELECT media_id FROM keep_media WHERE reason = 'seed_parent')
LIMIT 400;

-- 7) Distinct uploaders (>=5) + null/empty uploaders
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT m.id, 'uploader'
FROM src.media m
JOIN src.project_media pm ON pm.media_id = m.id
WHERE m.current_uploader IN (
  SELECT current_uploader FROM (
    SELECT current_uploader, COUNT(*) AS n
    FROM src.media m2
    JOIN src.project_media pm2 ON pm2.media_id = m2.id AND pm2.project_id IN (7, 14, 9)
    WHERE m2.current_uploader IS NOT NULL AND trim(m2.current_uploader) <> ''
    GROUP BY current_uploader
    ORDER BY n DESC
    LIMIT 8
  )
)
ORDER BY m.id
LIMIT 500;

INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT m.id, 'uploader_null'
FROM src.media m
JOIN src.project_media pm ON pm.media_id = m.id AND pm.project_id IN (7, 14, 9)
WHERE m.current_uploader IS NULL OR trim(m.current_uploader) = ''
ORDER BY m.id
LIMIT 150;

-- 8) Multi project_media memberships
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT media_id, 'multi_project'
FROM (
  SELECT media_id, COUNT(DISTINCT project_id) AS np
  FROM src.project_media
  GROUP BY media_id
  HAVING np > 1
  ORDER BY np DESC, media_id
  LIMIT 600
);

-- 9) Prefer media that have downloads (thumbs / finalize)
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT d.media_id, 'has_download'
FROM src.downloads d
JOIN src.project_media pm ON pm.media_id = d.media_id AND pm.project_id = 7
WHERE d.local_path IS NOT NULL AND trim(d.local_path) <> ''
ORDER BY d.media_id
LIMIT 1000;

-- 10) Fill remaining quota from project 7 (spread, not first IDs: every Nth after offset)
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT media_id, 'fill_p7'
FROM (
  SELECT media_id,
         ROW_NUMBER() OVER (ORDER BY media_id) AS rn
  FROM src.project_media
  WHERE project_id = 7
)
WHERE (rn % 17) = 3
LIMIT $target;

-- Cap soft: if still short, add more spread from p14
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT media_id, 'fill_p14'
FROM (
  SELECT media_id, ROW_NUMBER() OVER (ORDER BY media_id) AS rn
  FROM src.project_media
  WHERE project_id = 14
)
WHERE (rn % 11) = 5
LIMIT $target;

-- Close parent FK gaps for discoveries.parent_media_id
INSERT OR IGNORE INTO keep_media(media_id, reason)
SELECT DISTINCT parent_media_id, 'parent_fk'
FROM src.discoveries
WHERE media_id IN (SELECT media_id FROM keep_media)
  AND parent_media_id IS NOT NULL;

-- If over target, keep priority reasons first via temp rebuild
CREATE TABLE keep_media_final (
  media_id INTEGER PRIMARY KEY,
  reason TEXT NOT NULL
);

INSERT INTO keep_media_final(media_id, reason)
SELECT media_id, reason FROM (
  SELECT media_id, reason,
         CASE reason
           WHEN 'range_p7' THEN 1
           WHEN 'deep_cat_origin' THEN 2
           WHEN 'cat_fallback' THEN 3
           WHEN 'multi_provenance' THEN 4
           WHEN 'series' THEN 5
           WHEN 'seed_parent' THEN 6
           WHEN 'seed_child' THEN 7
           WHEN 'uploader' THEN 8
           WHEN 'uploader_null' THEN 9
           WHEN 'multi_project' THEN 10
           WHEN 'has_download' THEN 11
           WHEN 'parent_fk' THEN 12
           ELSE 50
         END AS prio,
         ROW_NUMBER() OVER (
           ORDER BY
             CASE reason
               WHEN 'range_p7' THEN 1
               WHEN 'deep_cat_origin' THEN 2
               WHEN 'cat_fallback' THEN 3
               WHEN 'multi_provenance' THEN 4
               WHEN 'series' THEN 5
               WHEN 'seed_parent' THEN 6
               WHEN 'seed_child' THEN 7
               WHEN 'uploader' THEN 8
               WHEN 'uploader_null' THEN 9
               WHEN 'multi_project' THEN 10
               WHEN 'has_download' THEN 11
               WHEN 'parent_fk' THEN 12
               ELSE 50
             END,
             media_id
         ) AS rn
  FROM keep_media
)
WHERE rn <= $target OR prio <= 12;

-- Always re-add parent FKs after cap
INSERT OR IGNORE INTO keep_media_final(media_id, reason)
SELECT DISTINCT parent_media_id, 'parent_fk'
FROM src.discoveries
WHERE media_id IN (SELECT media_id FROM keep_media_final)
  AND parent_media_id IS NOT NULL;

DELETE FROM keep_media;
INSERT INTO keep_media SELECT * FROM keep_media_final;
DROP TABLE keep_media_final;

CREATE TABLE keep_projects (project_id INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO keep_projects SELECT id FROM src.projects WHERE id IN (7, 8, 9, 14, 1, 16, 15);
INSERT OR IGNORE INTO keep_projects
SELECT DISTINCT project_id FROM src.project_media WHERE media_id IN (SELECT media_id FROM keep_media);

-- Copy reference / metadata tables fully (small)
INSERT INTO main.schema_migrations SELECT * FROM src.schema_migrations;
INSERT INTO main.review_schema_migrations SELECT * FROM src.review_schema_migrations;
INSERT INTO main.review_provenance_type_map SELECT * FROM src.review_provenance_type_map;
INSERT INTO main.projects SELECT * FROM src.projects WHERE id IN (SELECT project_id FROM keep_projects);

-- Categories: all referenced by keep projects' project_categories + discovery origins + fallback titles
CREATE TABLE keep_categories (category_id INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO keep_categories
SELECT category_id FROM src.project_categories WHERE project_id IN (SELECT project_id FROM keep_projects);
INSERT OR IGNORE INTO keep_categories
SELECT DISTINCT origin_category_id FROM src.discoveries
WHERE media_id IN (SELECT media_id FROM keep_media) AND origin_category_id IS NOT NULL;
INSERT OR IGNORE INTO keep_categories
SELECT c.id FROM src.categories c
JOIN src.discoveries d ON c.normalized_title = lower(d.source_value)
WHERE d.media_id IN (SELECT media_id FROM keep_media)
  AND d.source_type = 'category'
  AND d.origin_category_id IS NULL;

-- Walk parent_category_id within project_categories for kept projects
INSERT OR IGNORE INTO keep_categories
SELECT DISTINCT parent_category_id FROM src.project_categories
WHERE project_id IN (SELECT project_id FROM keep_projects)
  AND parent_category_id IS NOT NULL;

INSERT INTO main.categories SELECT * FROM src.categories WHERE id IN (SELECT category_id FROM keep_categories);

INSERT INTO main.project_categories
SELECT * FROM src.project_categories
WHERE project_id IN (SELECT project_id FROM keep_projects)
  AND category_id IN (SELECT category_id FROM keep_categories);

-- Optional closure if present
INSERT INTO main.project_category_closure
SELECT * FROM src.project_category_closure
WHERE project_id IN (SELECT project_id FROM keep_projects)
  AND ancestor_id IN (SELECT category_id FROM keep_categories)
  AND descendant_id IN (SELECT category_id FROM keep_categories);

INSERT INTO main.media SELECT * FROM src.media WHERE id IN (SELECT media_id FROM keep_media);

INSERT INTO main.project_media
SELECT * FROM src.project_media
WHERE media_id IN (SELECT media_id FROM keep_media)
  AND project_id IN (SELECT project_id FROM keep_projects);

INSERT INTO main.discoveries
SELECT * FROM src.discoveries
WHERE media_id IN (SELECT media_id FROM keep_media)
  AND project_id IN (SELECT project_id FROM keep_projects);

INSERT INTO main.downloads
SELECT * FROM src.downloads
WHERE media_id IN (SELECT media_id FROM keep_media);

INSERT INTO main.project_downloads
SELECT * FROM src.project_downloads
WHERE media_id IN (SELECT media_id FROM keep_media)
  AND project_id IN (SELECT project_id FROM keep_projects);

INSERT INTO main.media_series_keys
SELECT * FROM src.media_series_keys
WHERE media_id IN (SELECT media_id FROM keep_media);

INSERT INTO main.media_review_batches
SELECT * FROM src.media_review_batches
WHERE project_id IN (SELECT project_id FROM keep_projects)
LIMIT 50;

INSERT INTO main.media_review_history
SELECT * FROM src.media_review_history
WHERE media_id IN (SELECT media_id FROM keep_media)
ORDER BY id DESC
LIMIT 5000;

INSERT INTO main.media_review_status
SELECT * FROM src.media_review_status
WHERE media_id IN (SELECT media_id FROM keep_media);

-- Seed all four review statuses (source often sparse-empty for current status)
INSERT OR IGNORE INTO main.media_review_status(project_id, media_id, status, changed_at, source, action, batch_id)
SELECT 7, km.media_id, 'keep', '2026-08-15T08:00:00.000Z', 'dev-mini', 'seed_status', 'dev-mini-seed-keep'
FROM keep_media km
JOIN main.project_media pm ON pm.project_id = 7 AND pm.media_id = km.media_id
WHERE (km.media_id % 40) = 1
LIMIT 200;

INSERT OR IGNORE INTO main.media_review_status(project_id, media_id, status, changed_at, source, action, batch_id)
SELECT 7, km.media_id, 'reject', '2026-08-15T08:00:01.000Z', 'dev-mini', 'seed_status', 'dev-mini-seed-reject'
FROM keep_media km
JOIN main.project_media pm ON pm.project_id = 7 AND pm.media_id = km.media_id
WHERE (km.media_id % 40) = 2
LIMIT 200;

INSERT OR IGNORE INTO main.media_review_status(project_id, media_id, status, changed_at, source, action, batch_id)
SELECT 7, km.media_id, 'unsure', '2026-08-15T08:00:02.000Z', 'dev-mini', 'seed_status', 'dev-mini-seed-unsure'
FROM keep_media km
JOIN main.project_media pm ON pm.project_id = 7 AND pm.media_id = km.media_id
WHERE (km.media_id % 40) = 3
LIMIT 200;

-- explicit unreviewed row (rare) + sparse default for the rest
INSERT OR IGNORE INTO main.media_review_status(project_id, media_id, status, changed_at, source, action, batch_id)
SELECT 7, km.media_id, 'unreviewed', '2026-08-15T08:00:03.000Z', 'dev-mini', 'seed_status', 'dev-mini-seed-unreviewed'
FROM keep_media km
JOIN main.project_media pm ON pm.project_id = 7 AND pm.media_id = km.media_id
WHERE (km.media_id % 40) = 4
LIMIT 50;

INSERT OR IGNORE INTO main.media_review_batches(
  batch_id, project_id, action, target_status, protect_keep,
  media_count, changed_count, protected_count, created_at, source, session_id
) VALUES
 ('dev-mini-seed-keep', 7, 'set_status', 'keep', 1, 200, 200, 0, '2026-08-15T08:00:00.000Z', 'dev-mini', 'dev-mini'),
 ('dev-mini-seed-reject', 7, 'set_status', 'reject', 1, 200, 200, 0, '2026-08-15T08:00:01.000Z', 'dev-mini', 'dev-mini'),
 ('dev-mini-seed-unsure', 7, 'set_status', 'unsure', 1, 200, 200, 0, '2026-08-15T08:00:02.000Z', 'dev-mini', 'dev-mini'),
 ('dev-mini-seed-unreviewed', 7, 'set_status', 'unreviewed', 1, 50, 50, 0, '2026-08-15T08:00:03.000Z', 'dev-mini', 'dev-mini');

INSERT INTO main.media_review_history(project_id, media_id, old_status, new_status, changed_at, source, action, batch_id, session_id)
SELECT project_id, media_id, 'unreviewed', status, changed_at, source, action, batch_id, 'dev-mini'
FROM main.media_review_status
WHERE batch_id LIKE 'dev-mini-seed-%';

-- Representation report table (for docs)
CREATE TABLE IF NOT EXISTS _dev_mini_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT OR REPLACE INTO _dev_mini_meta(key, value) VALUES
 ('built_at', datetime('now')),
 ('source', '$srcUri'),
 ('target_media', '$target'),
 ('media_count', (SELECT CAST(COUNT(*) AS TEXT) FROM keep_media)),
 ('reason_counts', (
    SELECT group_concat(reason || '=' || c, ',')
    FROM (SELECT reason, COUNT(*) AS c FROM keep_media GROUP BY reason ORDER BY reason)
 ));

DETACH DATABASE src;
PRAGMA foreign_keys=ON;
"@

$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Sqlite -Database $workDb -Sql $buildSql
Write-Host ("Copy phase: {0:N1} s" -f $sw.Elapsed.TotalSeconds)

Write-Host "Integrity checks..."
$fk = (Invoke-Sqlite -Database $workDb -Sql 'PRAGMA foreign_key_check;' | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($fk)) {
    Write-Host "PRAGMA foreign_key_check: PASS (empty)" -ForegroundColor Green
} else {
    Write-Host $fk
    throw "foreign_key_check FAILED"
}
$qc = (Invoke-Sqlite -Database $workDb -Sql 'PRAGMA quick_check;' | Out-String).Trim()
if ($qc -ne 'ok') {
    throw "quick_check FAILED: $qc"
}
Write-Host "PRAGMA quick_check: PASS ($qc)" -ForegroundColor Green

if (-not $SkipVacuum) {
    Write-Host "VACUUM into output..."
    $outUri = $OutputDatabase.Replace('\', '/')
    Remove-Item -LiteralPath $OutputDatabase, "$OutputDatabase-wal", "$OutputDatabase-shm" -Force -ErrorAction SilentlyContinue
    Invoke-Sqlite -Database $workDb -Sql "VACUUM INTO '$outUri';"
} else {
    Copy-Item -LiteralPath $workDb -Destination $OutputDatabase -Force
}

Remove-Item -LiteralPath $workDb, "$workDb-wal", "$workDb-shm" -Force -ErrorAction SilentlyContinue

$outSize = (Get-Item -LiteralPath $OutputDatabase).Length
Write-Host ("Output size: {0:N2} MB" -f ($outSize / 1MB))

$afterCounts = [ordered]@{
    projects              = (Get-DbCount $OutputDatabase 'projects')
    media                 = (Get-DbCount $OutputDatabase 'media')
    project_media         = (Get-DbCount $OutputDatabase 'project_media')
    discoveries           = (Get-DbCount $OutputDatabase 'discoveries')
    downloads             = (Get-DbCount $OutputDatabase 'downloads')
    categories            = (Get-DbCount $OutputDatabase 'categories')
    project_categories    = (Get-DbCount $OutputDatabase 'project_categories')
    media_review_status   = (Get-DbCount $OutputDatabase 'media_review_status')
    media_review_history  = (Get-DbCount $OutputDatabase 'media_review_history')
    media_review_batches  = (Get-DbCount $OutputDatabase 'media_review_batches')
    media_series_keys     = (Get-DbCount $OutputDatabase 'media_series_keys')
    review_provenance_type_map = (Get-DbCount $OutputDatabase 'review_provenance_type_map')
}

Write-Host "`n=== Representation checks ===" -ForegroundColor Cyan
$repSql = @"
SELECT 'series_keys', COUNT(DISTINCT COALESCE(source_value, query_text))
FROM discoveries
WHERE source_type IN ('filename-series','time-series','filename')
  AND COALESCE(source_value, query_text) IS NOT NULL;
SELECT 'seed_parents', COUNT(DISTINCT parent_media_id) FROM discoveries WHERE parent_media_id IS NOT NULL;
SELECT 'uploaders', COUNT(DISTINCT current_uploader) FROM media WHERE current_uploader IS NOT NULL AND trim(current_uploader)<>'';
SELECT 'null_uploaders', COUNT(*) FROM media WHERE current_uploader IS NULL OR trim(current_uploader)='';
SELECT 'multi_project_media', COUNT(*) FROM (SELECT media_id FROM project_media GROUP BY media_id HAVING COUNT(DISTINCT project_id)>1);
SELECT 'origin_cat', COUNT(*) FROM discoveries WHERE source_type='category' AND origin_category_id IS NOT NULL;
SELECT 'fallback_cat', COUNT(*) FROM discoveries WHERE source_type='category' AND origin_category_id IS NULL AND source_value IS NOT NULL;
SELECT 'status_keep', COUNT(*) FROM media_review_status WHERE status='keep';
SELECT 'status_reject', COUNT(*) FROM media_review_status WHERE status='reject';
SELECT 'status_unsure', COUNT(*) FROM media_review_status WHERE status='unsure';
SELECT 'status_unreviewed', COUNT(*) FROM media_review_status WHERE status='unreviewed';
SELECT 'deep_pc', COUNT(*) FROM project_categories WHERE project_id=7 AND depth>=2;
SELECT 'source_types', COUNT(DISTINCT source_type) FROM discoveries;
SELECT 'reason_meta', value FROM _dev_mini_meta WHERE key='reason_counts';
"@
Invoke-Sqlite -Database $OutputDatabase -Sql $repSql -Readonly | ForEach-Object { Write-Host "  $_" }

# Write documentation JSON next to DB and in docs
$docDir = Join-Path $RepoRoot 'docs\review-mvp'
$docPath = Join-Path $docDir 'REVIEW_DEV_MINI_DB.md'
$builtAt = (Get-Date).ToUniversalTime().ToString('o')
$repLines = @(Invoke-Sqlite -Database $OutputDatabase -Sql $repSql -Readonly | ForEach-Object { "$_" })

$md = @"
# Review Dev Mini Database

**Built:** $builtAt  
**Script:** ``review/db/scripts/New-ReviewDevMiniDatabase.ps1``  
**Output:** ``$OutputDatabase``

## Role

| DB | Use |
|---|---|
| ``review-dev-mini.db`` | **Default** for Entwicklung, Unit/Integration, Browser-E2E |
| Full gate / 100k+ copy (``findseries-v5-phase1-gate.db`` etc.) | **Only** explicit Performance-, Migration- oder Real-DB-Acceptance-Tests |
| Production ``FindSeriesV5-Workspace\findseries-v5.db`` | **Never** for writes/tests |

## Size

| | Bytes | Human |
|---|---:|---|
| Source (before) | $srcSize | $([math]::Round($srcSize/1GB, 2)) GB |
| Mini (after) | $outSize | $([math]::Round($outSize/1MB, 2)) MB |

## Row counts (main tables)

| Table | Before (source) | After (mini) |
|---|---:|---:|
$(($beforeCounts.Keys | ForEach-Object { "| ``$_`` | $($beforeCounts[$_]) | $($afterCounts[$_]) |" }) -join "`n")

## Integrity

- ``PRAGMA foreign_key_check``: PASS (empty)
- ``PRAGMA quick_check``: PASS (ok)

## Representativeness (post-build probes)

``````
$($repLines -join "`n")
``````

Sampling is stratified (deep categories, origin + source_value fallback, multi-provenance, series, seeds, uploaders/null, multi-project membership, consecutive ranges, seeded four review statuses + batch/history). **Not** first-N media IDs.

## Rebuild

``````powershell
powershell -NoProfile -ExecutionPolicy Bypass -File review\db\scripts\New-ReviewDevMiniDatabase.ps1
``````

## Env default

``REVIEW_DB_PATH=C:\Temp\FindSeries-Review-Test\review-dev-mini.db``  
Perf benches: set ``REVIEW_DB_PATH`` / ``REVIEW_PERF_DB_PATH`` to the full gate copy explicitly.
"@

Set-Content -LiteralPath $docPath -Value $md -Encoding UTF8
Write-Host "Wrote $docPath" -ForegroundColor Green
Write-Host "MINI_DB_OK media=$($afterCounts.media) path=$OutputDatabase" -ForegroundColor Green
