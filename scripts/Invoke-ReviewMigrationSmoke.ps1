# Optional FRV-42 smoke: copy tiny phase-1 fixture → migrate 100–105 → quick_check.
# Not a CI gate DB; never touches production / 19GB databases.
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $env:TEMP ("findseries-review-mig-smoke-" + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixturePs1 = Join-Path $root 'review\db\tests\New-Phase1TestDatabase.ps1'
$migratePs1 = Join-Path $root 'review\db\Invoke-ReviewMigrations.ps1'
$sqlite = Join-Path $root 'Tools\sqlite3.exe'

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$sourceDb = Join-Path $WorkDir 'phase1-source.db'
$copyDb = Join-Path $WorkDir 'phase1-migrated-copy.db'

Write-Host "WorkDir: $WorkDir" -ForegroundColor Cyan
& $fixturePs1 -DatabasePath $sourceDb -SqlitePath $sqlite -RepoRoot $root
if ($LASTEXITCODE -ne 0) { throw 'fixture creation failed' }

# SQLite backup into a temp copy (simulates "migrierte DB-Kopie")
$copyUnix = $copyDb.Replace('\', '/')
& $sqlite $sourceDb ".backup main `"$copyUnix`""
if ($LASTEXITCODE -ne 0) { throw 'sqlite backup failed' }

& $migratePs1 -DatabasePath $copyDb -SqlitePath $sqlite
if ($LASTEXITCODE -ne 0) { throw 'migration failed' }

$versions = & $sqlite $copyDb "SELECT group_concat(version) FROM (SELECT version FROM review_schema_migrations WHERE version BETWEEN 100 AND 105 ORDER BY version);"
$qc = & $sqlite $copyDb 'PRAGMA quick_check;'
Write-Host "review_schema_migrations: $versions"
Write-Host "quick_check: $qc"
if (($versions | Select-Object -Last 1) -ne '100,101,102,103,104,105') {
    throw "unexpected versions: $versions"
}
if (($qc | Select-Object -Last 1).Trim() -ne 'ok') {
    throw "quick_check failed: $qc"
}

Write-Host "PASS migration smoke on temp fixture copy" -ForegroundColor Green
Write-Host "Temp DB (optional inspect): $copyDb" -ForegroundColor DarkGray
