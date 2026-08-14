[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$SourceWorkspace,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$TargetWorkspace,
    [string]$SqlitePath
)

$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath($SourceWorkspace)
$target=[IO.Path]::GetFullPath($TargetWorkspace)
if($source.TrimEnd('\') -eq $target.TrimEnd('\')){throw 'SourceWorkspace und TargetWorkspace müssen verschieden sein.'}

$sourceDb=Join-Path $source 'findseries-v5.db'
$targetDb=Join-Path $target 'findseries-v5.db'
$sourceMedia=Join-Path $source 'Media'
$targetMedia=Join-Path $target 'Media'
$sourceReview=Join-Path $source 'Review'
$targetReview=Join-Path $target 'Review'

if(-not(Test-Path -LiteralPath $sourceDb -PathType Leaf)){throw "Quelldatenbank fehlt: $sourceDb"}
if([string]::IsNullOrWhiteSpace($SqlitePath)){$SqlitePath=Join-Path $PSScriptRoot 'Tools\sqlite3.exe'}
$sqlite=[IO.Path]::GetFullPath($SqlitePath)
if(-not(Test-Path -LiteralPath $sqlite -PathType Leaf)){throw "sqlite3.exe fehlt: $sqlite"}

# A live writer must never be copied. Check the command line rather than only
# process names so unrelated PowerShell sessions are not touched.
$running=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'powershell|pwsh' -and
    -not[string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
    $_.CommandLine -match 'FindSeries' -and
    $_.CommandLine.IndexOf($source,[StringComparison]::OrdinalIgnoreCase) -ge 0
})
if($running.Count -gt 0){
    throw "FindSeries verwendet den Quell-Workspace noch. Lauf zuerst sauber beenden. PID(s): $(@($running.ProcessId) -join ', ')"
}

New-Item -ItemType Directory -Path $target -Force|Out-Null
foreach($name in @('Projects','Logs','Temp')){
    New-Item -ItemType Directory -Path (Join-Path $target $name) -Force|Out-Null
}

if(Test-Path -LiteralPath $targetDb){throw "Zieldatenbank existiert bereits: $targetDb"}
$escapedTarget=$targetDb.Replace("'","''")
& $sqlite $sourceDb ".timeout 60000" ".backup '$escapedTarget'"
if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $targetDb -PathType Leaf)){
    throw 'SQLite-Backup in den lokalen Workspace ist fehlgeschlagen.'
}

# Large media stay on the existing external SSD. Directory junctions are local
# filesystem metadata and do not require moving hundreds of GB.
if(Test-Path -LiteralPath $sourceMedia -PathType Container){
    if(Test-Path -LiteralPath $targetMedia){throw "Media-Ziel existiert bereits: $targetMedia"}
    New-Item -ItemType Junction -Path $targetMedia -Target $sourceMedia|Out-Null
}
if(Test-Path -LiteralPath $sourceReview -PathType Container){
    if(-not(Test-Path -LiteralPath $targetReview)){
        New-Item -ItemType Junction -Path $targetReview -Target $sourceReview|Out-Null
    }
}else{
    New-Item -ItemType Directory -Path $targetReview -Force|Out-Null
}

Write-Host ''
Write-Host 'Lokaler FindSeries-Workspace vorbereitet.' -ForegroundColor Green
Write-Host ("  DB lokal : {0}" -f $targetDb)
Write-Host ("  Media    : {0} -> {1}" -f $targetMedia,$sourceMedia)
if(Test-Path -LiteralPath $targetReview){Write-Host ("  Review   : {0}" -f $targetReview)}
Write-Host ''
Write-Host 'Ab jetzt FindSeries nur noch mit diesem Workspace starten:' -ForegroundColor Cyan
Write-Host ("  -Workspace `"{0}`"" -f $target)
Write-Host 'Nicht zwischen alter und neuer DB wechseln; der alte Workspace bleibt nur als Sicherheitskopie bestehen.' -ForegroundColor Yellow
