# Applies Review-MVP migrations 100–104 idempotently on a DB copy.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabasePath,
    [string]$SqlitePath,
    [string]$MigrationsDir,
    [switch]$Backup,
    [switch]$SkipIntegrity
)
$ErrorActionPreference='Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if(-not $SqlitePath){$SqlitePath=Join-Path $root 'Tools\sqlite3.exe'}
if(-not $MigrationsDir){$MigrationsDir=Join-Path $root 'review\db\migrations'}
if(-not(Test-Path -LiteralPath $SqlitePath)){throw "sqlite3 not found: $SqlitePath"}
if(-not(Test-Path -LiteralPath $DatabasePath)){throw "database not found: $DatabasePath"}

$versions=@(100,101,102,103,104)
$files=@(
    '100_review_status.sql',
    '101_provenance_map.sql',
    '102_category_graph.sql',
    '103_series_keys.sql',
    '104_similarity_meta.sql'
)

function Get-CoreCounts([string]$Db){
    & $SqlitePath $Db @"
SELECT
 (SELECT COUNT(*) FROM projects),
 (SELECT COUNT(*) FROM media),
 (SELECT COUNT(*) FROM project_media),
 (SELECT COUNT(*) FROM discoveries),
 (SELECT COUNT(*) FROM categories),
 (SELECT COUNT(*) FROM project_categories);
"@
}

Write-Host "Database: $DatabasePath" -ForegroundColor Cyan
if($Backup){
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak="$DatabasePath.pre-review-mig-$stamp.bak"
    Copy-Item -LiteralPath $DatabasePath -Destination $bak -Force
    foreach($s in @('-wal','-shm')){
        $side=$DatabasePath+$s
        if(Test-Path -LiteralPath $side){Copy-Item -LiteralPath $side -Destination ($bak+$s) -Force}
    }
    Write-Host "Backup: $bak" -ForegroundColor DarkGray
}

$before=Get-CoreCounts $DatabasePath
Write-Host "Counts before: $before"
if(-not $SkipIntegrity){
    $qc=& $SqlitePath $DatabasePath 'PRAGMA quick_check;'
    if($qc -ne 'ok'){throw "quick_check failed before migration: $qc"}
}

foreach($f in $files){
    $path=Join-Path $MigrationsDir $f
    if(-not(Test-Path -LiteralPath $path)){throw "missing migration: $path"}
    Write-Host "Apply $f ..." -ForegroundColor Gray
    & $SqlitePath $DatabasePath ".read `"$($path.Replace('\','/'))`""
    if($LASTEXITCODE -ne 0){throw "migration failed: $f"}
}

$after=Get-CoreCounts $DatabasePath
Write-Host "Counts after: $after"
if($before -cne $after){throw "core counts changed: $before -> $after"}

$applied=& $SqlitePath $DatabasePath "SELECT version FROM schema_migrations WHERE version IN (100,101,102,103,104) ORDER BY version;"
$appliedList=@($applied)
foreach($v in $versions){
    if($appliedList -notcontains [string]$v){throw "missing schema_migrations version $v"}
}
if(-not $SkipIntegrity){
    $qc2=& $SqlitePath $DatabasePath 'PRAGMA quick_check;'
    if($qc2 -ne 'ok'){throw "quick_check failed after migration: $qc2"}
}
Write-Host "Migration OK. Versions:`n$($appliedList -join ', ')" -ForegroundColor Green

<#
Rollback scenario (documented, not auto-executed):
1. Stop review-api / writers.
2. Restore $DatabasePath from the .bak (+ wal/shm if present) created with -Backup.
3. Or: DROP review_* / media_review_* / media_series_keys / media_embedding* / media_phash / project_category_closure
   and DELETE FROM schema_migrations WHERE version BETWEEN 100 AND 104;
   Prefer full file restore for safety.
#>
