# Synchronize Explorer review folders with the global rejection list.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Project,
    [string]$Workspace,
    [string]$SqlitePath,
    [int]$MaxExports=-1,
    [switch]$Open
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Review.psm1') -Force -DisableNameChecking

$init=Initialize-FsDatabase -Workspace $Workspace -SqlitePath $SqlitePath
$sqlite=$init.SqlitePath;$db=$init.Paths.Database
$projectRow=Get-FsProjectByName -SqlitePath $sqlite -DatabasePath $db -Name $Project
if($null -eq $projectRow){throw "Project nicht gefunden: $Project"}
$config=$null
if(-not[string]::IsNullOrWhiteSpace([string]$projectRow.config_json)){
    $config=ConvertTo-FsHashtable ([string]$projectRow.config_json|ConvertFrom-Json)
}
if($null -eq $config){
    $profile=if([string]::IsNullOrWhiteSpace([string]$projectRow.profile)){'Balanced'}else{[string]$projectRow.profile}
    $config=Get-FsProjectConfig -Profile $profile -ProfilesPath (Join-Path $PSScriptRoot 'Config\profiles.json')
}
$runLock=$null
try{
    $runLock=Open-FsProjectRunLock -Workspace $init.Paths.Root -ProjectId ([int]$projectRow.id) -ProjectName ([string]$projectRow.name)
    $summary=Sync-FsReview -ProjectId ([int]$projectRow.id) -Workspace $init.Paths.Root -Config $config -SqlitePath $sqlite -DatabasePath $db -MaxExports $MaxExports
    if($Open -and $summary.Enabled -and (Test-Path -LiteralPath $summary.Root)){
        Invoke-Item -LiteralPath $summary.Root
    }
    $summary
}
finally{Close-FsProjectRunLock -Lock $runLock}
