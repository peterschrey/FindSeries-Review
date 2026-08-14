[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('category','query','metadata','neighbor','download')][string]$TaskType,
    [Parameter(Mandatory=$true)][int]$ProjectId,
    [Parameter(Mandatory=$true)][int]$RunId,
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$SqlitePath,
    [Parameter(Mandatory=$true)][string]$WorkerName,
    [Parameter(Mandatory=$true)][string]$ConfigJson,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$ApplicationRoot
)

$ErrorActionPreference='Stop'
$clock=[Diagnostics.Stopwatch]::StartNew()
$itemsProcessed=0
$lastHeartbeat=[DateTime]::UtcNow
$db=Join-Path $Workspace 'findseries-v5.db'
$modulesLoaded=$false

try {
    Write-Output ("[WORKER] {0}: Initialisierung für Stufe '{1}' ..." -f $WorkerName,$TaskType)

    $root=[IO.Path]::GetFullPath($ApplicationRoot)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){
        throw "Programmverzeichnis des Workers fehlt: $root"
    }
    Write-Output ("[WORKER] {0}: Programmverzeichnis {1}" -f $WorkerName,$root)
    Import-Module (Join-Path $root 'Modules\FindSeries.Database.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Modules\FindSeries.Core.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Modules\FindSeries.Api.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Modules\FindSeries.Search.psm1') -Force -DisableNameChecking
    $modulesLoaded=$true

    $config=ConvertTo-FsHashtable ($ConfigJson|ConvertFrom-Json)
    [void](Initialize-FsDiagnostics -Config $config -Workspace $Workspace -ProjectId $ProjectId -RunId $RunId -Worker $WorkerName -Stage $TaskType)
    $headers=Get-FsHttpHeaders -Config $config -Version '5.0.14-hotfix66'
    $mediaRoot=Join-Path $Workspace 'Media'

    Write-Output ("[WORKER] {0}: bereit nach {1:N1}s; Datenbank {2}" -f $WorkerName,$clock.Elapsed.TotalSeconds,$db)

    while($true) {
        # Run-active validation is part of the atomic task claim. This avoids
        # one separate sqlite3 process before every work item.
        $worked=switch($TaskType) {
            'category' { Invoke-FsCategoryWorkerItem -ProjectId $ProjectId -RunId $RunId -Worker $WorkerName -Config $config -SqlitePath $SqlitePath -DatabasePath $db -Headers $headers }
            'query' { Invoke-FsQueryWorkerItem -ProjectId $ProjectId -RunId $RunId -Worker $WorkerName -Config $config -SqlitePath $SqlitePath -DatabasePath $db -Headers $headers }
            'metadata' { Invoke-FsMetadataWorkerItem -ProjectId $ProjectId -RunId $RunId -Worker $WorkerName -Config $config -SqlitePath $SqlitePath -DatabasePath $db -Headers $headers }
            'neighbor' { Invoke-FsNeighborWorkerItem -ProjectId $ProjectId -RunId $RunId -Worker $WorkerName -Config $config -SqlitePath $SqlitePath -DatabasePath $db -Headers $headers }
            'download' { Invoke-FsDownloadWorkerItem -ProjectId $ProjectId -RunId $RunId -Worker $WorkerName -Config $config -SqlitePath $SqlitePath -DatabasePath $db -MediaRoot $mediaRoot -Headers $headers }
        }

        # HF65: a download claim reconciliation retry is not completed work.
        # Continue immediately without inflating the worker counter.
        if($TaskType -eq 'download' -and [string]$worked -eq '__FS_RETRY__'){continue}
        if(-not $worked){break}

        $itemsProcessed++
        if($itemsProcessed -eq 1 -or ($itemsProcessed % 25) -eq 0 -or (([DateTime]::UtcNow-$lastHeartbeat).TotalSeconds -ge 30)) {
            Write-Output ("[WORKER] {0}: {1} Arbeitseinheit(en) verarbeitet; Laufzeit {2}" -f $WorkerName,$itemsProcessed,$clock.Elapsed.ToString('hh\:mm\:ss'))
            $lastHeartbeat=[DateTime]::UtcNow
        }
    }

    if($TaskType -eq 'download'){
        [void](Flush-FsDownloadCompletionQueue -ProjectId $ProjectId -Worker $WorkerName -Config $config -SqlitePath $SqlitePath -DatabasePath $db)
    }
    Write-Output ("[WORKER] {0}: regulär beendet; {1} Arbeitseinheit(en); Laufzeit {2}" -f $WorkerName,$itemsProcessed,$clock.Elapsed.ToString('hh\:mm\:ss'))
}
catch {
    $message=("Worker {0} in Stufe '{1}' fehlgeschlagen: {2}" -f $WorkerName,$TaskType,$_.Exception.Message)
    if($modulesLoaded){
        if($TaskType -eq 'download'){
            try { [void](Flush-FsDownloadCompletionQueue -ProjectId $ProjectId -Worker $WorkerName -Config $config -SqlitePath $SqlitePath -DatabasePath $db) } catch {}
        }
        try { Reset-FsWorkerTasks -ProjectId $ProjectId -Worker $WorkerName -SqlitePath $SqlitePath -DatabasePath $db -Reason $message -Stage $TaskType } catch {}
        try {
            Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $db -ProjectId $ProjectId -RunId $RunId -Stage $TaskType -Level 'error' -Message $message -Details @{stack=$_.ScriptStackTrace;worker=$WorkerName;items=$itemsProcessed}
        } catch {}
    }
    Write-Error $message
    throw
}
