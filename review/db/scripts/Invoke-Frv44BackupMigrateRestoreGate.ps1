<#
.SYNOPSIS
  FRV-44 reproducible Backup -> Migration 100-105 -> Review Smoke -> Restore gate.

.DESCRIPTION
  SOURCE (default: productive FindSeries DB) is opened ONLY as SQLite URI mode=ro
  for an online .backup into Temp. All migrations, smoke mutations, and restores
  run exclusively on Temp copies. Never writes to the productive path.
#>
[CmdletBinding()]
param(
    [string]$SourceDatabase = 'C:\FindSeriesV5-Workspace\findseries-v5.db',
    [string]$WorkDir = 'E:\Temp\FindSeries-Review-Test',
    [string]$SqlitePath,
    [string]$RepoRoot,
    [int]$IntegrityTimeoutMinutes = 20,
    [int]$PragmaTimeoutMinutes = 20,
    [switch]$ReuseExistingBaseline,
    [switch]$SkipIntegrity,
    [switch]$KeepWorkCopies,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$root = if ($RepoRoot) { (Resolve-Path -LiteralPath $RepoRoot).Path }
        else { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
if (-not $SqlitePath) { $SqlitePath = Join-Path $root 'Tools\sqlite3.exe' }
if (-not (Test-Path -LiteralPath $SqlitePath)) { throw "sqlite3 not found: $SqlitePath" }
if (-not (Test-Path -LiteralPath $SourceDatabase)) { throw "source DB missing: $SourceDatabase" }

$ProductionCanonical = [IO.Path]::GetFullPath('C:\FindSeriesV5-Workspace\findseries-v5.db').ToLowerInvariant()
$SourceCanonical = [IO.Path]::GetFullPath($SourceDatabase).ToLowerInvariant()

function Assert-NotProductionWriteTarget {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    if ($full -eq $ProductionCanonical) {
        throw "REFUSING write/migration/smoke on productive DB: $Path"
    }
}

function Write-Step {
    param([string]$Msg)
    Write-Host ""
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "=== [$ts] $Msg ===" -ForegroundColor Cyan
}

function Invoke-Sqlite {
    param(
        [Parameter(Mandatory=$true)][string]$Database,
        [Parameter(Mandatory=$true)][string]$Sql
    )
    Assert-NotProductionWriteTarget $Database
    $out = & $SqlitePath $Database $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("sqlite exit {0}: {1}" -f $LASTEXITCODE, ($out -join ' '))
    }
    return @($out)
}

function Invoke-SqliteBackup {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Dest
    )
    $destUnix = $Dest.Replace('\', '/')
    $out = & $SqlitePath $Source ".backup main `"$destUnix`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("sqlite backup exit {0}: {1}" -f $LASTEXITCODE, ($out -join ' '))
    }
}

function Remove-DbFiles {
    param([string]$DbPath)
    foreach ($suffix in @('', '-wal', '-shm')) {
        $p = $DbPath + $suffix
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            Remove-Item -LiteralPath $p -Force -ErrorAction Stop
        } catch {
            $stale = '{0}.stale-{1}' -f $p, (Get-Date -Format 'yyyyMMddHHmmss')
            Write-Host "WARN: locked $p - renaming to $stale" -ForegroundColor Yellow
            Move-Item -LiteralPath $p -Destination $stale -Force
        }
    }
}

function Invoke-PragmaWithTimeout {
    param(
        [string]$Database,
        [string]$PragmaSql,
        [int]$TimeoutMinutes,
        [string]$LogPath,
        [ValidateSet('ExpectOk','ExpectEmpty')][string]$SuccessMode = 'ExpectOk'
    )
    Assert-NotProductionWriteTarget $Database
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SqlitePath
    $psi.Arguments = ('"{0}" "{1}"' -f $Database, $PragmaSql)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while (-not $p.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) {
            try { $p.Kill() } catch { }
            $msg = "TIMEOUT after ${TimeoutMinutes}m for: $PragmaSql"
            Set-Content -LiteralPath $LogPath -Value $msg -Encoding UTF8
            return [ordered]@{ status = 'BLOCKED_TIMEOUT'; elapsedMs = $sw.ElapsedMilliseconds; exitCode = -1; output = $msg }
        }
        Start-Sleep -Seconds 5
        $sec = [int]$sw.Elapsed.TotalSeconds
        Write-Host ("  ... still running ({0}s): {1}" -f $sec, $PragmaSql) -ForegroundColor DarkGray
    }
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $combined = (@($stdout, $stderr) -join "`n").Trim()
    Set-Content -LiteralPath $LogPath -Value $combined -Encoding UTF8
    $ok = $false
    if ($p.ExitCode -eq 0) {
        if ($SuccessMode -eq 'ExpectOk') {
            $ok = ($combined -eq 'ok')
        } else {
            $ok = [string]::IsNullOrWhiteSpace($combined)
        }
    }
    $previewLen = [Math]::Min(500, $combined.Length)
    $preview = if ($previewLen -gt 0) { $combined.Substring(0, $previewLen) } else { '' }
    return [ordered]@{
        status    = $(if ($ok) { 'PASS' } else { 'FAIL' })
        elapsedMs = $sw.ElapsedMilliseconds
        exitCode  = $p.ExitCode
        output    = $preview
    }
}

function Get-DbSnapshot {
    param(
        [string]$Database,
        [int]$PragmaTimeoutMinutes = 5
    )
    Assert-NotProductionWriteTarget $Database
    $size = (Get-Item -LiteralPath $Database).Length
    $countSql = 'SELECT (SELECT COUNT(*) FROM projects),(SELECT COUNT(*) FROM media),(SELECT COUNT(*) FROM project_media),(SELECT COUNT(*) FROM discoveries),(SELECT COUNT(*) FROM downloads),(SELECT COUNT(*) FROM categories),(SELECT COUNT(*) FROM project_categories);'
    $countsRaw = (Invoke-Sqlite -Database $Database -Sql $countSql) -join ''
    $parts = $countsRaw.Trim() -split '\|'
    $coreSql = "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM schema_migrations ORDER BY version);"
    $coreMig = ((Invoke-Sqlite -Database $Database -Sql $coreSql) -join '').Trim()
    $hasReview = ((Invoke-Sqlite -Database $Database -Sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='review_schema_migrations';") -join '').Trim()
    $reviewMig = '(none)'
    if ($hasReview -eq '1') {
        $revSql = "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM review_schema_migrations WHERE version BETWEEN 100 AND 105 ORDER BY version);"
        $reviewMig = ((Invoke-Sqlite -Database $Database -Sql $revSql) -join '').Trim()
    }
    $fpSql = "SELECT printf('%s|tables=%s|indexes=%s',(SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM schema_migrations ORDER BY version)),(SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'),(SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'));"
    $schemaFp = ((Invoke-Sqlite -Database $Database -Sql $fpSql) -join '').Trim()

    $baseName = [IO.Path]::GetFileNameWithoutExtension($Database)
    $qcLog = Join-Path $logDir ("frv44-quick-{0}.log" -f $baseName)
    $qcRes = Invoke-PragmaWithTimeout -Database $Database -PragmaSql 'PRAGMA quick_check;' -TimeoutMinutes $PragmaTimeoutMinutes -LogPath $qcLog -SuccessMode ExpectOk
    if ($qcRes.status -eq 'BLOCKED_TIMEOUT') { throw "quick_check TIMEOUT on $Database (see $qcLog)" }
    $qc = if ($qcRes.status -eq 'PASS') { 'ok' } else { [string]$qcRes.output }

    $fkLog = Join-Path $logDir ("frv44-fk-{0}.log" -f $baseName)
    $fkRes = Invoke-PragmaWithTimeout -Database $Database -PragmaSql 'PRAGMA foreign_key_check;' -TimeoutMinutes $PragmaTimeoutMinutes -LogPath $fkLog -SuccessMode ExpectEmpty
    if ($fkRes.status -eq 'BLOCKED_TIMEOUT') { throw "foreign_key_check TIMEOUT on $Database (see $fkLog)" }
    $fkStatus = if ($fkRes.status -eq 'PASS') { 'PASS' } else { 'FAIL:' + $fkRes.output }

    return [ordered]@{
        databasePath           = $Database
        fileSizeBytes          = $size
        projects               = [long]$parts[0]
        media                  = [long]$parts[1]
        project_media          = [long]$parts[2]
        discoveries            = [long]$parts[3]
        downloads              = [long]$parts[4]
        categories             = [long]$parts[5]
        project_categories     = [long]$parts[6]
        coreSchemaMigrations   = $coreMig
        reviewSchemaMigrations = $reviewMig
        schemaFingerprint      = $schemaFp
        foreign_key_check      = $fkStatus
        quick_check            = $qc
    }
}

# ---- prep ----
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$logDir = Join-Path $WorkDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$reportDir = Join-Path $root 'docs\review-mvp\bench'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$baseline = Join-Path $WorkDir 'frv44-baseline.db'
$migrateWork = Join-Path $WorkDir 'frv44-migrate-work.db'
$restored = Join-Path $WorkDir 'frv44-restored.db'
$reportJson = Join-Path $reportDir 'frv44-gate-report.json'
$reportMd = Join-Path $root 'docs\review-mvp\FRV44_BACKUP_MIGRATE_RESTORE.md'

$report = [ordered]@{
    task                 = 'FRV-44'
    startedAt            = (Get-Date).ToUniversalTime().ToString('o')
    sourceDatabase       = $SourceDatabase
    sourceIsProduction   = ($SourceCanonical -eq $ProductionCanonical)
    workDir              = $WorkDir
    timingsMs            = [ordered]@{}
    steps                = [ordered]@{}
    blocked              = $false
    blockedReason        = $null
}

Write-Step '0) Preflight - source metadata (filesystem only, no SQLite write)'
$srcItemBefore = Get-Item -LiteralPath $SourceDatabase
$report.steps.preflight = [ordered]@{
    sourceExists           = $true
    sourceSizeBytes        = $srcItemBefore.Length
    sourceLastWriteTimeUtc = $srcItemBefore.LastWriteTimeUtc.ToString('o')
    note                   = 'No PRAGMA/migration/VACUUM on source. Backup uses file:...?mode=ro'
}

Write-Step '1) Online .backup from SOURCE (mode=ro) -> baseline'
$didBackup = $true
if ($ReuseExistingBaseline -and (Test-Path -LiteralPath $baseline)) {
    $existing = Get-Item -LiteralPath $baseline
    Write-Host ("Reusing existing baseline ({0:N0} bytes, mtime {1:u})" -f $existing.Length, $existing.LastWriteTimeUtc) -ForegroundColor Yellow
    $report.timingsMs.onlineBackup = 0
    $report.steps.backup = [ordered]@{ reused = $true; path = $baseline; fileSizeBytes = $existing.Length }
    $didBackup = $false
} else {
    Remove-DbFiles -DbPath $baseline
    $srcUnix = $SourceDatabase.Replace('\', '/')
    $srcUri = "file:${srcUnix}?mode=ro"
    $swBackup = [Diagnostics.Stopwatch]::StartNew()
    Invoke-SqliteBackup -Source $srcUri -Dest $baseline
    $swBackup.Stop()
    $report.timingsMs.onlineBackup = $swBackup.ElapsedMilliseconds
    Write-Host ("Backup done in {0:n1}s -> {1}" -f $swBackup.Elapsed.TotalSeconds, $baseline)
    $report.steps.backup = [ordered]@{ reused = $false; path = $baseline }
}

$srcItemAfter = Get-Item -LiteralPath $SourceDatabase
$report.steps.sourceUnchanged = [ordered]@{
    sizeBeforeBytes    = $srcItemBefore.Length
    sizeAfterBytes     = $srcItemAfter.Length
    lastWriteBeforeUtc = $srcItemBefore.LastWriteTimeUtc.ToString('o')
    lastWriteAfterUtc  = $srcItemAfter.LastWriteTimeUtc.ToString('o')
    sizeUnchanged      = ($srcItemBefore.Length -eq $srcItemAfter.Length)
    lastWriteUnchanged = ($srcItemBefore.LastWriteTimeUtc -eq $srcItemAfter.LastWriteTimeUtc)
    checkedAfterBackup = $didBackup
}
if ($didBackup -and (-not $report.steps.sourceUnchanged.sizeUnchanged)) {
    throw 'Production DB size changed during backup - STOP'
}
if ($didBackup -and (-not $report.steps.sourceUnchanged.lastWriteUnchanged)) {
    Write-Host 'WARN: production LastWriteTime changed during backup window (external writer?). Size unchanged; continuing.' -ForegroundColor Yellow
    $report.steps.sourceUnchanged.warning = 'lastWriteTime changed; size stable'
}

Write-Step '2) Baseline snapshot (counts, migrations, FK, quick_check)'
$swSnap = [Diagnostics.Stopwatch]::StartNew()
$baselineSnap = Get-DbSnapshot -Database $baseline -PragmaTimeoutMinutes $PragmaTimeoutMinutes
$swSnap.Stop()
$report.timingsMs.baselineSnapshot = $swSnap.ElapsedMilliseconds
$report.steps.baseline = $baselineSnap
if ($baselineSnap.quick_check -ne 'ok') { throw ("baseline quick_check failed: {0}" -f $baselineSnap.quick_check) }
if ($baselineSnap.foreign_key_check -ne 'PASS') { throw 'baseline foreign_key_check failed' }
Write-Host ("Baseline size={0:N0} media={1} reviewMig={2}" -f $baselineSnap.fileSizeBytes, $baselineSnap.media, $baselineSnap.reviewSchemaMigrations)

if (-not $SkipIntegrity) {
    Write-Step ("3) PRAGMA integrity_check on BASELINE (timeout {0}m)" -f $IntegrityTimeoutMinutes)
    $integLog = Join-Path $logDir 'frv44-baseline-integrity.log'
    $integ = Invoke-PragmaWithTimeout -Database $baseline -PragmaSql 'PRAGMA integrity_check;' -TimeoutMinutes $IntegrityTimeoutMinutes -LogPath $integLog -SuccessMode ExpectOk
    $report.timingsMs.integrity_check = $integ.elapsedMs
    $report.steps.integrity_check = $integ
    if ($integ.status -eq 'BLOCKED_TIMEOUT') {
        $report.blocked = $true
        $report.blockedReason = $integ.output
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportJson -Encoding UTF8
        throw ("FRV-44 BLOCKED: integrity_check exceeded {0} minutes. See {1}" -f $IntegrityTimeoutMinutes, $integLog)
    }
    if ($integ.status -ne 'PASS') {
        throw ("baseline integrity_check failed: {0}" -f $integ.output)
    }
} else {
    $report.steps.integrity_check = [ordered]@{ status = 'SKIPPED'; reason = '-SkipIntegrity' }
}

Write-Step '4) Baseline -> migrate-work copy (never migrate baseline in place)'
Remove-DbFiles -DbPath $migrateWork
$swCopy = [Diagnostics.Stopwatch]::StartNew()
Invoke-SqliteBackup -Source $baseline -Dest $migrateWork
$swCopy.Stop()
$report.timingsMs.copyToMigrateWork = $swCopy.ElapsedMilliseconds

Write-Step '5) Apply Review migrations 100-105 (twice for idempotency)'
$migratePs1 = Join-Path $root 'review\db\Invoke-ReviewMigrations.ps1'
$swMig = [Diagnostics.Stopwatch]::StartNew()
& $migratePs1 -DatabasePath $migrateWork -SqlitePath $SqlitePath -SkipIntegrity
& $migratePs1 -DatabasePath $migrateWork -SqlitePath $SqlitePath -SkipIntegrity
$swMig.Stop()
$report.timingsMs.migrationsIdempotent = $swMig.ElapsedMilliseconds

$postMig = Get-DbSnapshot -Database $migrateWork -PragmaTimeoutMinutes $PragmaTimeoutMinutes
$report.steps.postMigrate = $postMig
if ($postMig.reviewSchemaMigrations -ne '100,101,102,103,104,105') {
    throw ("expected review 100-105, got {0}" -f $postMig.reviewSchemaMigrations)
}
if ($postMig.coreSchemaMigrations -ne $baselineSnap.coreSchemaMigrations) {
    throw 'core schema_migrations changed'
}
$leaked = ((Invoke-Sqlite -Database $migrateWork -Sql 'SELECT COUNT(*) FROM schema_migrations WHERE version BETWEEN 100 AND 105;') -join '').Trim()
if ($leaked -ne '0') { throw 'Review versions leaked into core schema_migrations' }
foreach ($k in @('projects','media','project_media','discoveries','downloads','categories','project_categories')) {
    if ($postMig[$k] -ne $baselineSnap[$k]) {
        throw ("count mismatch after migrate for {0}" -f $k)
    }
}
if ($postMig.quick_check -ne 'ok') { throw 'post-migrate quick_check failed' }
if ($postMig.foreign_key_check -ne 'PASS') { throw 'post-migrate foreign_key_check failed' }

if (-not $SkipSmoke) {
    Write-Step '6) Review smoke on migrate-work (no physical finalize)'
    $smokeJs = Join-Path $root 'review\api\scripts\frv44-review-smoke.mjs'
    $swSmoke = [Diagnostics.Stopwatch]::StartNew()
    $prev = $env:REVIEW_DB_PATH
    $env:REVIEW_DB_PATH = $migrateWork
    try {
        Push-Location (Join-Path $root 'review\api')
        try {
            & node --import tsx $smokeJs
            if ($LASTEXITCODE -ne 0) { throw ("review smoke failed exit {0}" -f $LASTEXITCODE) }
        } finally { Pop-Location }
    } finally {
        if ($null -eq $prev) { Remove-Item Env:REVIEW_DB_PATH -ErrorAction SilentlyContinue }
        else { $env:REVIEW_DB_PATH = $prev }
    }
    $swSmoke.Stop()
    $report.timingsMs.reviewSmoke = $swSmoke.ElapsedMilliseconds
    $report.steps.reviewSmoke = [ordered]@{ status = 'PASS'; script = $smokeJs }
} else {
    $report.steps.reviewSmoke = [ordered]@{ status = 'SKIPPED' }
}

Write-Step '7) Restore test: baseline -> frv44-restored.db (never production)'
Remove-DbFiles -DbPath $restored
$swRestore = [Diagnostics.Stopwatch]::StartNew()
Invoke-SqliteBackup -Source $baseline -Dest $restored
$swRestore.Stop()
$report.timingsMs.restoreBackup = $swRestore.ElapsedMilliseconds

$restoredSnap = Get-DbSnapshot -Database $restored -PragmaTimeoutMinutes $PragmaTimeoutMinutes
$report.steps.restored = $restoredSnap

$compareKeys = @(
    'projects','media','project_media','discoveries','downloads','categories','project_categories',
    'coreSchemaMigrations','reviewSchemaMigrations','schemaFingerprint','quick_check','foreign_key_check'
)
$diffs = @()
foreach ($k in $compareKeys) {
    if (("$($baselineSnap[$k])") -ne ("$($restoredSnap[$k])")) {
        $diffs += ('{0} : baseline={1} restored={2}' -f $k, $baselineSnap[$k], $restoredSnap[$k])
    }
}
$report.steps.restoreCompare = [ordered]@{
    logicalEqual = ($diffs.Count -eq 0)
    diffs        = $diffs
}
if ($diffs.Count -gt 0) {
    throw ("restore logical compare failed:`n{0}" -f ($diffs -join "`n"))
}
Write-Host 'Restore logical compare: PASS' -ForegroundColor Green

$srcFinal = Get-Item -LiteralPath $SourceDatabase
$report.steps.sourceFinal = [ordered]@{
    sizeBytes                   = $srcFinal.Length
    lastWriteTimeUtc            = $srcFinal.LastWriteTimeUtc.ToString('o')
    sizeStillMatchesPreflight   = ($srcFinal.Length -eq $srcItemBefore.Length)
}
if (-not $report.steps.sourceFinal.sizeStillMatchesPreflight) {
    throw 'Production DB size changed by end of gate - STOP'
}

Write-Step '8) Cleanup work copies (keep baseline)'
if (-not $KeepWorkCopies) {
    Remove-DbFiles -DbPath $migrateWork
    Remove-DbFiles -DbPath $restored
    $report.steps.cleanup = [ordered]@{
        deleted = @($migrateWork, $restored)
        kept    = @($baseline)
    }
} else {
    $report.steps.cleanup = [ordered]@{ keptAll = $true }
}

$report.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
$report.status = 'PASS'
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportJson -Encoding UTF8

$integStatus = [string]$report.steps.integrity_check.status
$integSec = if ($report.timingsMs.integrity_check) { [math]::Round($report.timingsMs.integrity_check / 1000.0, 1) } else { 0 }
$timingLines = ($report.timingsMs.GetEnumerator() | ForEach-Object { '- {0}: {1}' -f $_.Key, $_.Value }) -join "`n"

$md = @"
# FRV-44 - Backup / Migration / Restore

**Status:** PASS
**Finished (UTC):** $($report.finishedAt)
**Source (read-only online backup only):** ``$SourceDatabase``
**Baseline:** ``$baseline``

## Safety

| Check | Result |
|---|---|
| Source opened as ``file:...?mode=ro`` for ``.backup`` | yes |
| Migrations / smoke / restore never on production | yes |
| Production size unchanged | $($report.steps.sourceUnchanged.sizeUnchanged) |
| Production LastWriteTime unchanged | $($report.steps.sourceUnchanged.lastWriteUnchanged) |

## Baseline

| Metric | Value |
|---|---|
| Size bytes | $($baselineSnap.fileSizeBytes) |
| projects | $($baselineSnap.projects) |
| media | $($baselineSnap.media) |
| project_media | $($baselineSnap.project_media) |
| discoveries | $($baselineSnap.discoveries) |
| downloads | $($baselineSnap.downloads) |
| categories | $($baselineSnap.categories) |
| project_categories | $($baselineSnap.project_categories) |
| core schema_migrations | $($baselineSnap.coreSchemaMigrations) |
| review_schema_migrations | $($baselineSnap.reviewSchemaMigrations) |
| schema fingerprint | $($baselineSnap.schemaFingerprint) |
| quick_check | $($baselineSnap.quick_check) |
| foreign_key_check | $($baselineSnap.foreign_key_check) |
| integrity_check | $integStatus ($integSec s) |

## Migration (work copy)

| Metric | Value |
|---|---|
| review_schema_migrations | $($postMig.reviewSchemaMigrations) |
| core schema_migrations unchanged | $($postMig.coreSchemaMigrations -eq $baselineSnap.coreSchemaMigrations) |
| core counts unchanged | yes |
| quick_check | $($postMig.quick_check) |
| foreign_key_check | $($postMig.foreign_key_check) |
| idempotent second apply | yes |

## Review smoke

$($report.steps.reviewSmoke.status) - projects/gallery/categories/groups/focus + status mutation + undo (no physical finalize).

## Restore

Logical equality baseline vs restored: **PASS** (byte-identical file hash not required).

## Timings (ms)

$timingLines

## Artifacts

- Machine report JSON: ``docs/review-mvp/bench/frv44-gate-report.json``
- Repro script: ``review/db/scripts/Invoke-Frv44BackupMigrateRestoreGate.ps1``
- Smoke: ``review/api/scripts/frv44-review-smoke.mjs``
- Kept on disk: ``$baseline``
- Deleted after gate: migrate-work + restored (unless ``-KeepWorkCopies``)

## How to re-run

``````powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File review/db/scripts/Invoke-Frv44BackupMigrateRestoreGate.ps1
``````
"@
Set-Content -LiteralPath $reportMd -Value $md -Encoding UTF8

Write-Host ""
Write-Host 'FRV-44 GATE PASS' -ForegroundColor Green
Write-Host "Report: $reportJson"
Write-Host "Markdown: $reportMd"
Write-Host "Baseline kept: $baseline"
