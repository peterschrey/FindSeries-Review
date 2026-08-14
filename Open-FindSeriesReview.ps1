# Synchronize and open the Explorer review folder.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Project,
    [string]$Workspace,
    [string]$SqlitePath,
    [int]$MaxExports=-1
)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Sync-FindSeriesReview.ps1') -Project $Project -Workspace $Workspace -SqlitePath $SqlitePath -MaxExports $MaxExports -Open
