# Remove a global review rejection and make matching project media downloadable again.
[CmdletBinding()]
param(
    [int]$MediaId=0,
    [Nullable[long]]$PageId,
    [string]$Sha1,
    [string]$Title,
    [string]$Workspace,
    [string]$SqlitePath
)
$ErrorActionPreference='Stop'
if($MediaId -le 0 -and ($null -eq $PageId -or [long]$PageId -le 0) -and [string]::IsNullOrWhiteSpace($Sha1) -and [string]::IsNullOrWhiteSpace($Title)){
    throw 'Mindestens -MediaId, -PageId, -Sha1 oder -Title muss angegeben werden.'
}
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Search.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Review.psm1') -Force -DisableNameChecking
$init=Initialize-FsDatabase -Workspace $Workspace -SqlitePath $SqlitePath
$result=Restore-FsRejectedMedia -SqlitePath $init.SqlitePath -DatabasePath $init.Paths.Database -MediaId $MediaId -PageId $PageId -Sha1 $Sha1 -Title $Title
Write-Host ("Globale Sperridentitäten entfernt: {0}; passende Medien reaktiviert: {1}." -f $result.RemovedRejections,$result.ReactivatedMedia) -ForegroundColor Green
$result
