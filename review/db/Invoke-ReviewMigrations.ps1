# Applies Review-MVP migrations 100–105 idempotently on a DB copy.
# Review versions are tracked in review_schema_migrations only (never core schema_migrations).
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabasePath,
    [string]$SqlitePath,
    [string]$MigrationsDir,
    [string]$BackupPath,
    [switch]$Backup,
    [switch]$SkipIntegrity
)
$ErrorActionPreference='Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if(-not $SqlitePath){$SqlitePath=Join-Path $root 'Tools\sqlite3.exe'}
if(-not $MigrationsDir){$MigrationsDir=Join-Path $root 'review\db\migrations'}
if(-not(Test-Path -LiteralPath $SqlitePath)){throw "sqlite3 not found: $SqlitePath"}
if(-not(Test-Path -LiteralPath $DatabasePath)){throw "database not found: $DatabasePath"}

$versions=@(100,101,102,103,104,105)
$files=@(
    '100_review_status.sql',
    '101_provenance_map.sql',
    '102_category_graph.sql',
    '103_series_keys.sql',
    '104_similarity_meta.sql',
    '105_review_perf_indexes.sql'
)

function Invoke-SqliteChecked {
    param([string]$Database,[Parameter(ValueFromRemainingArguments=$true)][string[]]$SqlArgs)
    $out = & $SqlitePath $Database @SqlArgs 2>&1
    if($LASTEXITCODE -ne 0){
        throw ("sqlite failed (exit {0}) on {1}: {2}" -f $LASTEXITCODE,$Database,($out -join ' '))
    }
    return $out
}

function Get-CoreCounts([string]$Database){
    (Invoke-SqliteChecked $Database @"
SELECT
 (SELECT COUNT(*) FROM projects),
 (SELECT COUNT(*) FROM media),
 (SELECT COUNT(*) FROM project_media),
 (SELECT COUNT(*) FROM discoveries),
 (SELECT COUNT(*) FROM categories),
 (SELECT COUNT(*) FROM project_categories),
 (SELECT COUNT(*) FROM downloads);
"@) -join ''
}

function Get-CoreMigrationFingerprint([string]$Database){
    (Invoke-SqliteChecked $Database "SELECT group_concat(version) FROM (SELECT version FROM schema_migrations ORDER BY version);") -join ''
}

function New-FsSqliteBackup {
    param([string]$SourceDb,[string]$DestDb)
    $destDir = Split-Path -Parent $DestDb
    if($destDir -and -not(Test-Path -LiteralPath $destDir)){
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    if(Test-Path -LiteralPath $DestDb){Remove-Item -LiteralPath $DestDb -Force}
    $destUnix = $DestDb.Replace('\','/')
    $null = Invoke-SqliteChecked $SourceDb ".backup main `"$destUnix`""
    $qc = (Invoke-SqliteChecked $DestDb 'PRAGMA quick_check;') -join ''
    if($qc.Trim() -ne 'ok'){throw "backup quick_check failed: $qc"}
    return (Resolve-Path -LiteralPath $DestDb).Path
}

Write-Host "Database: $DatabasePath" -ForegroundColor Cyan
if($Backup){
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    if([string]::IsNullOrWhiteSpace($BackupPath)){
        $BackupPath = "$DatabasePath.pre-review-mig-$stamp.sqlitebackup"
    }
    $bak = New-FsSqliteBackup -SourceDb $DatabasePath -DestDb $BackupPath
    Write-Host "SQLite .backup created: $bak" -ForegroundColor DarkGray
}

$before=Get-CoreCounts $DatabasePath
$coreMigBefore=Get-CoreMigrationFingerprint $DatabasePath
Write-Host "Counts before: $before"
Write-Host "Core schema_migrations before: $coreMigBefore"
if(-not $SkipIntegrity){
    $qc=(Invoke-SqliteChecked $DatabasePath 'PRAGMA quick_check;') -join ''
    if($qc.Trim() -ne 'ok'){throw "quick_check failed before migration: $qc"}
}

$timings = New-Object Collections.Generic.List[string]
foreach($f in $files){
    $path=Join-Path $MigrationsDir $f
    if(-not(Test-Path -LiteralPath $path)){throw "missing migration: $path"}
    Write-Host "Apply $f ..." -ForegroundColor Gray
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-SqliteChecked $DatabasePath ".read `"$($path.Replace('\','/'))`""
    $sw.Stop()
    $timings.Add(("{0}={1}ms" -f $f,$sw.ElapsedMilliseconds))
}

$after=Get-CoreCounts $DatabasePath
$coreMigAfter=Get-CoreMigrationFingerprint $DatabasePath
Write-Host "Counts after: $after"
Write-Host "Core schema_migrations after: $coreMigAfter"
if($before -cne $after){throw "core counts changed: $before -> $after"}
if($coreMigBefore -cne $coreMigAfter){throw "core schema_migrations changed by Review migrations: $coreMigBefore -> $coreMigAfter"}

$leaked=@(Invoke-SqliteChecked $DatabasePath "SELECT version FROM schema_migrations WHERE version IN (100,101,102,103,104,105) ORDER BY version;")
if(@($leaked | Where-Object { $_ -and $_.ToString().Trim() -ne '' }).Count -gt 0){
    throw ("Review versions leaked into core schema_migrations: {0}" -f ($leaked -join ','))
}

$applied=@(Invoke-SqliteChecked $DatabasePath "SELECT version FROM review_schema_migrations WHERE version IN (100,101,102,103,104,105) ORDER BY version;")
foreach($v in $versions){
    if($applied -notcontains [string]$v){throw "missing review_schema_migrations version $v"}
}
if(-not $SkipIntegrity){
    $qc2=(Invoke-SqliteChecked $DatabasePath 'PRAGMA quick_check;') -join ''
    if($qc2.Trim() -ne 'ok'){throw "quick_check failed after migration: $qc2"}
}
Write-Host ("Migration timings: {0}" -f ($timings -join '; ')) -ForegroundColor DarkGray
Write-Host "Migration OK. Review versions:`n$($applied -join ', ')" -ForegroundColor Green

<#
Rollback (supported):
1. Stop writers.
2. Restore from the SQLite .backup file created with -Backup.
3. Prefer backup-restore over SQL DROP scripts.

SQL rollback file ROLLBACK_100_104.sql is best-effort only (pre-105).
Migration 105 adds indexes only — drop via DROP INDEX IF EXISTS if needed.
#>
