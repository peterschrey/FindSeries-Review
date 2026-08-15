# FRV-44 Phases B-D on C:\Temp\...\frv44-work.db only. No E: SQLite I/O. No prod writes.
[CmdletBinding()]
param(
  [string]$WorkDb = 'C:\Temp\FindSeries-Review-Test\frv44-work.db',
  [string]$RepoRoot = 'C:\Users\pschr\cursor3-repos\FindSeries-Review',
  [int]$IntegrityTimeoutMinutes = 20,
  [double]$MinFreeGB = 10
)

$ErrorActionPreference = 'Stop'
$sqlite = Join-Path $RepoRoot 'Tools\sqlite3.exe'
$prod = 'C:\FindSeriesV5-Workspace\findseries-v5.db'
$logDir = 'E:\Temp\FindSeries-Review-Test\logs'
$benchDir = Join-Path $RepoRoot 'docs\review-mvp\bench'
New-Item -ItemType Directory -Force -Path $logDir,$benchDir | Out-Null

function Assert-WorkOnly([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
  $p = [IO.Path]::GetFullPath($prod).ToLowerInvariant()
  if ($full -eq $p) { throw 'REFUSING productive DB' }
  if ($full -notlike 'c:\*') { throw "REFUSING non-C work path: $Path" }
}

function Get-CFreeGB { [math]::Round((Get-PSDrive C).Free/1GB, 2) }

function Assert-FreeSpace {
  $f = Get-CFreeGB
  if ($f -lt $MinFreeGB) { throw ("STOP: C free {0} GB < {1} GB" -f $f, $MinFreeGB) }
  return $f
}

function Invoke-Sql([string]$Db, [string]$Sql) {
  Assert-WorkOnly $Db
  $out = & $sqlite $Db $Sql 2>&1
  if ($LASTEXITCODE -ne 0) { throw ("sqlite exit {0}: {1}" -f $LASTEXITCODE, ($out -join ' ')) }
  return (($out | Out-String).Trim())
}

function Invoke-PragmaTimed {
  param([string]$Db,[string]$Sql,[int]$TimeoutMin,[string]$LogPath,[ValidateSet('ok','empty')]$Mode)
  Assert-WorkOnly $Db
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $sqlite
  $psi.Arguments = ('"{0}" "{1}"' -f $Db, $Sql)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [void]$p.Start()
  $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMin)
  while (-not $p.HasExited) {
    Assert-FreeSpace | Out-Null
    if ([DateTime]::UtcNow -gt $deadline) {
      try { $p.Kill() } catch {}
      $msg = "TIMEOUT ${TimeoutMin}m: $Sql"
      Set-Content $LogPath $msg -Encoding UTF8
      return @{ status='BLOCKED_TIMEOUT'; elapsedMs=$sw.ElapsedMilliseconds; output=$msg }
    }
    Start-Sleep -Seconds 10
    Write-Host ("  [{0:n0}s] still: {1} | C free={2} GB" -f $sw.Elapsed.TotalSeconds, $Sql, (Get-CFreeGB))
  }
  $combined = (@($p.StandardOutput.ReadToEnd(), $p.StandardError.ReadToEnd()) -join "`n").Trim()
  Set-Content $LogPath $combined -Encoding UTF8
  $ok = $false
  if ($p.ExitCode -eq 0) {
    if ($Mode -eq 'ok') { $ok = ($combined -eq 'ok') }
    else { $ok = [string]::IsNullOrWhiteSpace($combined) }
  }
  return @{ status=$(if($ok){'PASS'}else{'FAIL'}); elapsedMs=$sw.ElapsedMilliseconds; exitCode=$p.ExitCode; output=$combined.Substring(0,[Math]::Min(400,$combined.Length)) }
}

Assert-WorkOnly $WorkDb
if (-not (Test-Path $WorkDb)) { throw "work db missing: $WorkDb" }

Write-Host '=== PHASE B baseline snapshot ===' -ForegroundColor Cyan
$cFreeStart = Assert-FreeSpace
$size = (Get-Item $WorkDb).Length

$counts = Invoke-Sql $WorkDb 'SELECT (SELECT COUNT(*) FROM projects),(SELECT COUNT(*) FROM media),(SELECT COUNT(*) FROM project_media),(SELECT COUNT(*) FROM discoveries),(SELECT COUNT(*) FROM downloads),(SELECT COUNT(*) FROM categories),(SELECT COUNT(*) FROM project_categories);'
$cp = $counts -split '\|'
$coreMig = Invoke-Sql $WorkDb "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM schema_migrations ORDER BY version);"
$hasRev = Invoke-Sql $WorkDb "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='review_schema_migrations';"
$revMig = '(none)'
if ($hasRev -eq '1') {
  $revMig = Invoke-Sql $WorkDb "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM review_schema_migrations WHERE version BETWEEN 100 AND 105 ORDER BY version);"
}
$fp = Invoke-Sql $WorkDb "SELECT printf('%s|tables=%s|indexes=%s',(SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM schema_migrations ORDER BY version)),(SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'),(SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'));"

Write-Host 'foreign_key_check...'
$fk = Invoke-PragmaTimed -Db $WorkDb -Sql 'PRAGMA foreign_key_check;' -TimeoutMin 20 -LogPath (Join-Path $logDir 'frv44-work-fk-pre.log') -Mode empty
Write-Host ("FK={0} {1}ms" -f $fk.status, $fk.elapsedMs)
Assert-FreeSpace | Out-Null

Write-Host 'quick_check...'
$qc = Invoke-PragmaTimed -Db $WorkDb -Sql 'PRAGMA quick_check;' -TimeoutMin 20 -LogPath (Join-Path $logDir 'frv44-work-qc-pre.log') -Mode ok
Write-Host ("QC={0} {1}ms" -f $qc.status, $qc.elapsedMs)
Assert-FreeSpace | Out-Null

Write-Host 'integrity_check (max 20m)...'
$ic = Invoke-PragmaTimed -Db $WorkDb -Sql 'PRAGMA integrity_check;' -TimeoutMin $IntegrityTimeoutMinutes -LogPath (Join-Path $logDir 'frv44-work-integrity-pre.log') -Mode ok
Write-Host ("IC={0} {1}ms" -f $ic.status, $ic.elapsedMs)
$cFreeAfterChecks = Assert-FreeSpace

$baselineSnap = [ordered]@{
  capturedAt = (Get-Date).ToUniversalTime().ToString('o')
  databasePath = $WorkDb
  fileSizeBytes = $size
  projects = [long]$cp[0]
  media = [long]$cp[1]
  project_media = [long]$cp[2]
  discoveries = [long]$cp[3]
  downloads = [long]$cp[4]
  categories = [long]$cp[5]
  project_categories = [long]$cp[6]
  coreSchemaMigrations = $coreMig
  reviewTablePresent = ($hasRev -eq '1')
  reviewSchemaMigrations = $revMig
  schemaFingerprint = $fp
  foreign_key_check = $fk
  quick_check = $qc
  integrity_check = $ic
  cFreeGBStart = $cFreeStart
  cFreeGBAfterChecks = $cFreeAfterChecks
}
$snapPath = Join-Path $benchDir 'frv44-ssd-baseline-snapshot.json'
$baselineSnap | ConvertTo-Json -Depth 6 | Set-Content $snapPath -Encoding UTF8
Write-Host "Snapshot written: $snapPath"

if ($fk.status -ne 'PASS' -or $qc.status -ne 'PASS' -or $ic.status -ne 'PASS') {
  $report = [ordered]@{ status='BLOCKED'; reason='baseline checks not all PASS'; baseline=$baselineSnap }
  $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $benchDir 'frv44-ssd-interim-report.json') -Encoding UTF8
  throw ("PHASE B BLOCKED: FK={0} QC={1} IC={2}" -f $fk.status, $qc.status, $ic.status)
}

Write-Host '=== PHASE C migrations 100-105 ===' -ForegroundColor Cyan
$mig = Join-Path $RepoRoot 'review\db\Invoke-ReviewMigrations.ps1'
$swMig = [Diagnostics.Stopwatch]::StartNew()
& $mig -DatabasePath $WorkDb -SqlitePath $sqlite -SkipIntegrity
Assert-FreeSpace | Out-Null
& $mig -DatabasePath $WorkDb -SqlitePath $sqlite -SkipIntegrity
$swMig.Stop()
Assert-FreeSpace | Out-Null

$revAfter = Invoke-Sql $WorkDb "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM review_schema_migrations WHERE version BETWEEN 100 AND 105 ORDER BY version);"
$coreAfter = Invoke-Sql $WorkDb "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM schema_migrations ORDER BY version);"
$leaked = Invoke-Sql $WorkDb 'SELECT COUNT(*) FROM schema_migrations WHERE version BETWEEN 100 AND 105;'
if ($revAfter -ne '100,101,102,103,104,105') { throw "review versions unexpected: $revAfter" }
if ($coreAfter -ne $coreMig) { throw "core migrations changed: $coreAfter" }
if ($leaked -ne '0') { throw "review versions leaked into core: $leaked" }

Write-Host 'post-migrate FK...'
$fk2 = Invoke-PragmaTimed -Db $WorkDb -Sql 'PRAGMA foreign_key_check;' -TimeoutMin 20 -LogPath (Join-Path $logDir 'frv44-work-fk-post.log') -Mode empty
Write-Host 'post-migrate quick_check...'
$qc2 = Invoke-PragmaTimed -Db $WorkDb -Sql 'PRAGMA quick_check;' -TimeoutMin 20 -LogPath (Join-Path $logDir 'frv44-work-qc-post.log') -Mode ok
if ($fk2.status -ne 'PASS' -or $qc2.status -ne 'PASS') { throw ("post-mig checks FAIL FK={0} QC={1}" -f $fk2.status, $qc2.status) }

$postMig = [ordered]@{
  reviewSchemaMigrations = $revAfter
  coreSchemaMigrations = $coreAfter
  coreUnchanged = ($coreAfter -eq $coreMig)
  leakedReviewIntoCore = [int]$leaked
  idempotentSecondApply = $true
  migrationSeconds = [math]::Round($swMig.Elapsed.TotalSeconds,1)
  foreign_key_check = $fk2
  quick_check = $qc2
  fileSizeBytes = (Get-Item $WorkDb).Length
}

Write-Host '=== PHASE D review smoke ===' -ForegroundColor Cyan
$env:REVIEW_DB_PATH = $WorkDb
Push-Location (Join-Path $RepoRoot 'review\api')
try {
  $smokeOut = & node --import tsx .\scripts\frv44-review-smoke.mjs 2>&1
  $smokeCode = $LASTEXITCODE
} finally { Pop-Location }
Write-Host ($smokeOut | Out-String)
if ($smokeCode -ne 0) { throw "smoke failed exit $smokeCode" }
$smokeJson = ($smokeOut | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)

$interim = [ordered]@{
  status = 'PASS_READY_FOR_RESTORE'
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  phaseA = (Get-Content (Join-Path $benchDir 'frv44-phase-a-copy.json') -Raw | ConvertFrom-Json)
  baselineSnapshot = $baselineSnap
  postMigrate = $postMig
  reviewSmoke = @{ exitCode=$smokeCode; output=("$smokeOut"); parsed=$smokeJson }
  workDb = @{ path=$WorkDb; bytes=(Get-Item $WorkDb).Length }
  cFreeGBNow = (Get-CFreeGB)
  notes = 'No restore yet. Work DB kept. No integrity after migration per DoD.'
}
$interimPath = Join-Path $benchDir 'frv44-ssd-interim-report.json'
$interim | ConvertTo-Json -Depth 10 | Set-Content $interimPath -Encoding UTF8

$md = @"
# FRV-44 SSD Interim Report (pre-restore)

**Status:** PASS - ready for restore phase
**Finished (UTC):** $($interim.finishedAt)

## Phase A Copy
- Source: ``E:\Temp\FindSeries-Review-Test\frv44-baseline.db``
- Dest: ``$WorkDb``
- Seconds: $($interim.phaseA.copySeconds)
- Bytes: $($interim.phaseA.destBytes)
- C free after copy: $($interim.phaseA.cFreeGBAfter) GB

## Phase B Baseline (pre-migration)
| Metric | Value |
|---|---|
| Size | $($baselineSnap.fileSizeBytes) |
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
| foreign_key_check | $($fk.status) ($([math]::Round($fk.elapsedMs/1000.0,1))s) |
| quick_check | $($qc.status) ($([math]::Round($qc.elapsedMs/1000.0,1))s) |
| integrity_check | $($ic.status) ($([math]::Round($ic.elapsedMs/1000.0,1))s) |

## Phase C Migration
- review_schema_migrations: **$revAfter**
- core unchanged: **$($postMig.coreUnchanged)**
- leaked into core: **$leaked**
- idempotent second apply: yes
- seconds: $($postMig.migrationSeconds)
- post FK: $($fk2.status)
- post quick: $($qc2.status)

## Phase D Smoke
``````
$smokeOut
``````

## Space
- C free now: **$((Get-CFreeGB)) GB**
- Work DB path/size: ``$WorkDb`` / $((Get-Item $WorkDb).Length) bytes

## Next
Restore phase not started. Work DB retained.
"@
$mdPath = Join-Path $RepoRoot 'docs\review-mvp\FRV44_SSD_INTERIM.md'
Set-Content $mdPath $md -Encoding UTF8
Write-Host "INTERIM_OK $interimPath"
Write-Host "MD $mdPath"
Write-Host 'READY FOR FRV-44 RESTORE PHASE'
