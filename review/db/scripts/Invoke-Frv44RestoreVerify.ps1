# FRV-44 restore verification against saved SSD baseline snapshot. C: only for SQLite.
[CmdletBinding()]
param(
  [string]$RestoredDb = 'C:\Temp\FindSeries-Review-Test\frv44-restored.db',
  [string]$SnapshotPath = 'C:\Users\pschr\cursor3-repos\FindSeries-Review\docs\review-mvp\bench\frv44-ssd-baseline-snapshot.json',
  [string]$RepoRoot = 'C:\Users\pschr\cursor3-repos\FindSeries-Review'
)
$ErrorActionPreference = 'Stop'
$sqlite = Join-Path $RepoRoot 'Tools\sqlite3.exe'
$bench = Join-Path $RepoRoot 'docs\review-mvp\bench'
$prod = [IO.Path]::GetFullPath('C:\FindSeriesV5-Workspace\findseries-v5.db').ToLowerInvariant()
$full = [IO.Path]::GetFullPath($RestoredDb).ToLowerInvariant()
if ($full -eq $prod) { throw 'REFUSING prod' }
if ($full -notlike 'c:\*') { throw 'REFUSING non-C path' }
if (-not (Test-Path $RestoredDb)) { throw "missing $RestoredDb" }

$snap = Get-Content $SnapshotPath -Raw | ConvertFrom-Json

function Sql([string]$q) {
  $o = & $sqlite $RestoredDb $q 2>&1
  if ($LASTEXITCODE -ne 0) { throw ("sql fail: {0}" -f ($o -join ' ')) }
  return (($o | Out-String).Trim())
}

function PragmaTimed([string]$sql, [string]$mode, [string]$log) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $sqlite
  $psi.Arguments = ('"{0}" "{1}"' -f $RestoredDb, $sql)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [void]$p.Start()
  while (-not $p.HasExited) {
    if ($sw.Elapsed.TotalMinutes -gt 20) { try{$p.Kill()}catch{}; throw "TIMEOUT $sql" }
    Start-Sleep 10
    Write-Host ("  [{0:n0}s] {1}" -f $sw.Elapsed.TotalSeconds, $sql)
  }
  $out = (@($p.StandardOutput.ReadToEnd(), $p.StandardError.ReadToEnd()) -join "`n").Trim()
  Set-Content $log $out -Encoding UTF8
  $ok = if ($mode -eq 'ok') { $out -eq 'ok' } else { [string]::IsNullOrWhiteSpace($out) }
  if (-not $ok -or $p.ExitCode -ne 0) { throw ("FAIL {0}: {1}" -f $sql, $out) }
  return @{ status='PASS'; elapsedMs=$sw.ElapsedMilliseconds }
}

Write-Host '=== Restore logical compare ===' -ForegroundColor Cyan
$counts = Sql 'SELECT (SELECT COUNT(*) FROM projects),(SELECT COUNT(*) FROM media),(SELECT COUNT(*) FROM project_media),(SELECT COUNT(*) FROM discoveries),(SELECT COUNT(*) FROM downloads),(SELECT COUNT(*) FROM categories),(SELECT COUNT(*) FROM project_categories);'
$cp = $counts -split '\|'
$core = Sql "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM schema_migrations ORDER BY version);"
$hasRev = Sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='review_schema_migrations';"
$rev = '(none)'
if ($hasRev -eq '1') {
  $rev = Sql "SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM review_schema_migrations WHERE version BETWEEN 100 AND 105 ORDER BY version);"
}
$fp = Sql "SELECT printf('%s|tables=%s|indexes=%s',(SELECT IFNULL(group_concat(version),'(none)') FROM (SELECT version FROM schema_migrations ORDER BY version)),(SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'),(SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'));"
$userVersion = Sql 'PRAGMA user_version;'
$pageSize = Sql 'PRAGMA page_size;'

$expectedCore = '1,2,11,12,13,30,32,34,42,44,52,62,65'
$diffs = @()
$map = @{
  projects = [long]$cp[0]
  media = [long]$cp[1]
  project_media = [long]$cp[2]
  discoveries = [long]$cp[3]
  downloads = [long]$cp[4]
  categories = [long]$cp[5]
  project_categories = [long]$cp[6]
}
foreach ($k in @($map.Keys)) {
  $got = $map[$k]
  $exp = [long]$snap.$k
  if ($got -ne $exp) { $diffs += ('{0}: restored={1} snap={2}' -f $k, $got, $exp) }
}
if ($core -ne $snap.coreSchemaMigrations) { $diffs += "coreMig: $core vs $($snap.coreSchemaMigrations)" }
if ($core -ne $expectedCore) { $diffs += "coreMig unexpected: $core" }
if ($fp -ne $snap.schemaFingerprint) { $diffs += "fingerprint: $fp vs $($snap.schemaFingerprint)" }
if ($hasRev -eq '1' -and $rev -ne '(none)' -and $rev -ne '') {
  $diffs += "review versions present after restore: $rev"
}
if ($snap.reviewTablePresent -eq $false -and $hasRev -eq '1') {
  $diffs += 'review_schema_migrations table present but baseline had none'
}

# Negative: media #1 must be sparse-unreviewed (no media_review_status row) if table absent OK;
# if table somehow exists, no row for media 1
$media1Status = 'n/a-no-review-table'
if ($hasRev -eq '1') {
  $row = Sql "SELECT IFNULL((SELECT status FROM media_review_status WHERE project_id=7 AND media_id=1),'(sparse)');"
  $media1Status = $row
  if ($row -ne '(sparse)') { $diffs += "media#1 status not sparse: $row" }
} else {
  $media1Status = 'sparse-unreviewed (no review tables)'
}

Write-Host 'FK...'
$fk = PragmaTimed 'PRAGMA foreign_key_check;' 'empty' 'E:\Temp\FindSeries-Review-Test\logs\frv44-restored-fk.log'
Write-Host 'quick_check...'
$qc = PragmaTimed 'PRAGMA quick_check;' 'ok' 'E:\Temp\FindSeries-Review-Test\logs\frv44-restored-qc.log'

$result = [ordered]@{
  status = $(if ($diffs.Count -eq 0) { 'PASS' } else { 'FAIL' })
  diffs = $diffs
  restored = [ordered]@{
    path = $RestoredDb
    fileSizeBytes = (Get-Item $RestoredDb).Length
    counts = $map
    coreSchemaMigrations = $core
    reviewTablePresent = ($hasRev -eq '1')
    reviewSchemaMigrations = $rev
    schemaFingerprint = $fp
    user_version = $userVersion
    page_size = $pageSize
    media1 = $media1Status
    foreign_key_check = $fk
    quick_check = $qc
  }
  baselineFingerprintExactMatch = ($fp -eq $snap.schemaFingerprint)
  baselineCoreExactMatch = ($core -eq $snap.coreSchemaMigrations)
  negativeProof = [ordered]@{
    noReview100_105 = ($rev -eq '(none)' -or $hasRev -eq '0')
    media1BaselineSparse = ($media1Status -like '*sparse*')
  }
}
$out = Join-Path $bench 'frv44-restore-compare.json'
$result | ConvertTo-Json -Depth 8 | Set-Content $out -Encoding UTF8
if ($diffs.Count -gt 0) {
  Write-Host ($diffs -join "`n") -ForegroundColor Red
  throw 'RESTORE_COMPARE_FAIL'
}
Write-Host 'RESTORE_COMPARE_PASS'
Write-Host ("fingerprint={0}" -f $fp)
Write-Host ("user_version={0} page_size={1}" -f $userVersion, $pageSize)
Write-Host ("media1={0}" -f $media1Status)
