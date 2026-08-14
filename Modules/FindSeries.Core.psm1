Set-StrictMode -Version 2.0

function ConvertTo-FsSlug {
    param([Parameter(Mandatory = $true)][string]$Text)
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder
    foreach ($ch in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$builder.Append($ch) }
    }
    $slug = $builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'project-' + [Guid]::NewGuid().ToString('N').Substring(0,8) }
    if ($slug.Length -gt 100) { $slug = $slug.Substring(0,100).Trim('-') }
    return $slug
}

function ConvertTo-FsHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        $h = @{}
        foreach ($key in $InputObject.Keys) { $h[[string]$key] = ConvertTo-FsHashtable $InputObject[$key] }
        return $h
    }
    if ($InputObject -is [pscustomobject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-FsHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        return @($InputObject | ForEach-Object { ConvertTo-FsHashtable $_ })
    }
    return $InputObject
}

function Merge-FsHashtable {
    param([hashtable]$Base,[hashtable]$Overlay)
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = ConvertTo-FsHashtable $Base[$key] }
    foreach ($key in $Overlay.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
            $result[$key] = Merge-FsHashtable -Base $result[$key] -Overlay $Overlay[$key]
        }
        else { $result[$key] = ConvertTo-FsHashtable $Overlay[$key] }
    }
    return $result
}

function Set-FsConfigPath {
    param([hashtable]$Config,[string]$Path,$Value)
    $parts = $Path -split '\.'
    $node = $Config
    for ($i=0; $i -lt $parts.Count-1; $i++) {
        $part = $parts[$i]
        if (-not $node.ContainsKey($part) -or -not ($node[$part] -is [hashtable])) { $node[$part] = @{} }
        $node = $node[$part]
    }
    $raw = [string]$Value
    $converted = $Value
    if ($raw -match '^(?i:true|false)$') { $converted = [bool]::Parse($raw) }
    elseif ($raw -match '^-?\d+$') { $converted = [int64]$raw }
    elseif ($raw -match '^-?\d+[\.,]\d+$') { $converted = [double]($raw.Replace(',','.')) }
    $node[$parts[-1]] = $converted
}

function Get-FsProjectConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfilesPath,
        [string]$ConfigPath,
        [string[]]$Override = @()
    )
    if (-not (Test-Path -LiteralPath $ProfilesPath)) { throw "Profil-Datei fehlt: $ProfilesPath" }
    $profiles = ConvertTo-FsHashtable ((Get-Content -LiteralPath $ProfilesPath -Raw -Encoding UTF8) | ConvertFrom-Json)
    if (-not $profiles.ContainsKey($Profile)) { throw "Unbekanntes Profil '$Profile'. Verfügbar: $($profiles.Keys -join ', ')" }
    $config = ConvertTo-FsHashtable $profiles[$Profile]
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $custom = ConvertTo-FsHashtable ((Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json)
        $config = Merge-FsHashtable -Base $config -Overlay $custom
    }
    foreach ($item in @($Override)) {
        if ($item -notmatch '^(?<path>[^=]+)=(?<value>.*)$') { throw "Ungültiges -Set '$item'. Erwartet: Bereich.Wert=Inhalt" }
        Set-FsConfigPath -Config $config -Path $matches.path.Trim() -Value $matches.value.Trim()
    }
    return $config
}


function Get-FsHttpUserAgent {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Config,
        [string]$Version='5.0.14-hotfix66'
    )

    $explicit=$null
    if($Config.ContainsKey('Api') -and $Config.Api -is [hashtable] -and $Config.Api.ContainsKey('UserAgent')){
        $explicit=[string]$Config.Api.UserAgent
    }
    if(-not[string]::IsNullOrWhiteSpace($explicit)){
        $userAgent=$explicit.Trim()
    }else{
        $contact=$null
        if($Config.ContainsKey('Api') -and $Config.Api -is [hashtable] -and $Config.Api.ContainsKey('Contact')){
            $contact=[string]$Config.Api.Contact
        }
        if([string]::IsNullOrWhiteSpace($contact)){
            throw 'Api.Contact fehlt. Wikimedia-Abrufe benötigen einen identifizierbaren User-Agent mit Kontaktangabe, z. B. Api.Contact=mailto:name@example.org.'
        }
        $contact=$contact.Trim()
        $psVersion=if($null -ne $PSVersionTable -and $null -ne $PSVersionTable.PSVersion){$PSVersionTable.PSVersion.ToString()}else{'unknown'}
        $userAgent="FindSeriesBot/$Version (Wikimedia Commons research; $contact) PowerShell/$psVersion"
    }

    if($userAgent -notmatch '(?i)bot'){
        throw "Api.UserAgent muss den automatisierten Client eindeutig als Bot kennzeichnen: $userAgent"
    }
    if($userAgent -notmatch '(?i)(mailto:|https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:^|[; (])User:[^) ;]+)'){
        throw "Api.UserAgent enthält keine erkennbare Kontaktangabe: $userAgent"
    }
    return $userAgent
}

function Get-FsHttpHeaders {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Config,
        [string]$Version='5.0.14-hotfix66'
    )
    $userAgent=Get-FsHttpUserAgent -Config $Config -Version $Version
    return @{
        'User-Agent'=$userAgent
        'Accept-Encoding'='gzip'
    }
}

function Get-FsModeStages {
    param([string]$Mode,[switch]$ListOnly)
    $stages = switch ($Mode) {
        'Categories' { @('category','metadata') }
        'Keywords'   { @('query','metadata') }
        'Combined'   { @('category','query','metadata') }
        'Depicts'    { @('query','metadata') }
        'Neighbours' { @('neighbor','metadata') }
        'Download'   { @('download') }
        'Full'       { @('category','query','metadata','neighbor','metadata','download') }
        'Resume'     { @('category','query','metadata','neighbor','metadata','download') }
        'Status'     { @() }
        default      { throw "Unbekannter Modus: $Mode" }
    }
    if ($ListOnly) { $stages = @($stages | Where-Object { $_ -ne 'download' }) }
    return @($stages)
}

function Get-FsWorkerCount {
    param([hashtable]$Config,[string]$Stage,[int]$OverrideWorkers)

    $requested=if($OverrideWorkers -gt 0){$OverrideWorkers}else{
        switch ($Stage) {
            'category' { [int]$Config.Category.Workers }
            'query' { [int]$Config.Keyword.Workers }
            'metadata' { [int]$Config.Metadata.Workers }
            'neighbor' { [int]$Config.Neighbors.Workers }
            'download' { [int]$Config.Download.Workers }
            default { 1 }
        }
    }
    # Hotfix 28: worker counts are controlled exclusively by profile/CLI.
    # No stage-specific safety cap silently rewrites the requested value.
    return [Math]::Max(1,[int]$requested)
}

function Get-FsStageCounts {
    param([string]$SqlitePath,[string]$DatabasePath,[int]$ProjectId,[string]$Stage,[int]$MaxAttempts=4)
    $table = switch ($Stage) {
        'category' { 'project_categories' }
        'query' { 'search_tasks' }
        'metadata' { 'metadata_tasks' }
        'neighbor' { 'neighbor_tasks' }
        'download' { 'project_downloads' }
        default { throw "Unbekannte Stufe: $Stage" }
    }
    $sql = @"
SELECT CASE WHEN status='failed' AND attempts<$MaxAttempts THEN 'retryable' ELSE status END status,
       COUNT(*) count
FROM $table
WHERE project_id=$ProjectId
GROUP BY CASE WHEN status='failed' AND attempts<$MaxAttempts THEN 'retryable' ELSE status END;
"@
    $rows = Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query
    $result = @{ pending=0; running=0; done=0; retryable=0; failed=0; skipped=0; reused=0 }
    foreach ($row in @($rows)) { $result[[string]$row.status] = [int]$row.count }
    return $result
}

function Get-FsStageRunningDetails {
    param(
        [string]$SqlitePath,
        [string]$DatabasePath,
        [int]$ProjectId,
        [string]$Stage
    )

    $sql = switch ($Stage) {
        'category' {
            @"
SELECT COALESCE(c.title,'?') item,
       COALESCE(pc.depth,0) depth,
       COALESCE(pc.member_count,0) processed,
       COALESCE(pc.lease_owner,'?') worker
FROM project_categories pc
LEFT JOIN categories c ON c.id=pc.category_id
WHERE pc.project_id=$ProjectId AND pc.status='running'
ORDER BY pc.updated_at
LIMIT 3;
"@
        }
        'query' {
            @"
SELECT COALESCE(query_text,'?') item,
       COALESCE(language,'?') language,
       COALESCE(results_count,0) processed,
       COALESCE(max_results,0) maximum,
       COALESCE(lease_owner,'?') worker
FROM search_tasks
WHERE project_id=$ProjectId AND status='running'
ORDER BY updated_at
LIMIT 3;
"@
        }
        'metadata' {
            @"
SELECT COALESCE(m.canonical_title,m.title,'?') item,
       COALESCE(mt.required_level,0) required_level,
       COALESCE(mt.lease_owner,'?') worker
FROM metadata_tasks mt
LEFT JOIN media m ON m.id=mt.media_id
WHERE mt.project_id=$ProjectId AND mt.status='running'
ORDER BY mt.updated_at
LIMIT 3;
"@
        }
        'neighbor' {
            @"
SELECT COALESCE(m.canonical_title,m.title,'?') item,
       COALESCE(nt.api_pages,0) api_pages,
       COALESCE(nt.results_count,0) processed,
       COALESCE(nt.lease_owner,'?') worker
FROM neighbor_tasks nt
LEFT JOIN media m ON m.id=nt.media_id
WHERE nt.project_id=$ProjectId AND nt.status='running'
ORDER BY nt.updated_at
LIMIT 3;
"@
        }
        'download' {
            @"
SELECT COALESCE(m.canonical_title,m.title,'?') item,
       COALESCE(pd.lease_owner,'?') worker
FROM project_downloads pd
LEFT JOIN media m ON m.id=pd.media_id
WHERE pd.project_id=$ProjectId AND pd.status='running'
ORDER BY pd.updated_at
LIMIT 3;
"@
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$sql)) { return @() }
    return @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query)
}

function Format-FsStageDuration {
    param([double]$Seconds)
    if ($Seconds -lt 0) { return '--:--' }
    $span = [TimeSpan]::FromSeconds($Seconds)
    if ($span.TotalDays -ge 1) { return $span.ToString('d\.hh\:mm\:ss') }
    if ($span.TotalHours -ge 1) { return $span.ToString('hh\:mm\:ss') }
    return $span.ToString('mm\:ss')
}

function Format-FsStageCompletionTime {
    param([Nullable[DateTime]]$Value)
    if($null -eq $Value){return '--'}
    return ([DateTime]$Value).ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss')
}

function Get-FsWorkerStartSpacingSeconds {
    param([hashtable]$Config,[string]$Stage)
    if($Stage -ne 'download'){return 0}
    if($null -ne $Config -and $Config.ContainsKey('Download') -and $Config.Download.ContainsKey('WorkerStartSpacingSeconds')){
        return [Math]::Max(0,[int]$Config.Download.WorkerStartSpacingSeconds)
    }
    return 15
}

function Start-FsStageWorkerJob {
    param(
        [string]$WorkerPath,[string]$Stage,[int]$ProjectId,[int]$RunId,[string]$Workspace,[string]$SqlitePath,
        [string]$ConfigJson,[string]$ApplicationRoot,[int]$Slot,[int]$Restart
    )
    $workerName = "{0}-r{1}-p{2}-s{3}-n{4}" -f $Stage,$RunId,$PID,$Slot,$Restart
    $argumentList = @($Stage,$ProjectId,$RunId,$Workspace,$SqlitePath,$workerName,$ConfigJson,$ApplicationRoot)
    $job = Start-Job -FilePath $WorkerPath -ArgumentList $argumentList -Name $workerName
    $job | Add-Member -NotePropertyName FsSlot -NotePropertyValue $Slot -Force
    $job | Add-Member -NotePropertyName FsRestart -NotePropertyValue $Restart -Force
    $job | Add-Member -NotePropertyName FsHandled -NotePropertyValue $false -Force
    return $job
}

function Start-FsStageWorkers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$WorkerPath,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Stage,
        [int]$ProjectId,
        [int]$RunId,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Workspace,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$SqlitePath,
        [hashtable]$Config,
        [int]$Workers,
        [int]$PollSeconds=2,
        [int]$TextProgressSeconds=10,
        [int]$StallWarningSeconds=60
    )

    $WorkerPath=[IO.Path]::GetFullPath($WorkerPath)
    if(-not(Test-Path -LiteralPath $WorkerPath -PathType Leaf)){throw "Worker-Skript fehlt: $WorkerPath"}
    $applicationRoot=Split-Path -Parent $WorkerPath
    if([string]::IsNullOrWhiteSpace($applicationRoot)){throw "Programmverzeichnis des Workers konnte nicht bestimmt werden: $WorkerPath"}
    foreach($requiredModule in @('Modules\FindSeries.Database.psm1','Modules\FindSeries.Core.psm1','Modules\FindSeries.Api.psm1','Modules\FindSeries.Search.psm1')){
        $requiredPath=Join-Path $applicationRoot $requiredModule
        if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "Worker-Modul fehlt: $requiredPath"}
    }

    $databasePath=Join-Path $Workspace 'findseries-v5.db'
    $configJson=$Config|ConvertTo-Json -Depth 20 -Compress
    $jobs=New-Object System.Collections.ArrayList
    $workerTarget=[Math]::Max(1,$Workers)
    $maxRestarts=2
    if($Config.ContainsKey('Progress') -and $Config.Progress.ContainsKey('WorkerRestarts')){$maxRestarts=[Math]::Max(0,[int]$Config.Progress.WorkerRestarts)}
    $restartCounts=@{}
    $maxAttempts=4
    if($Config.ContainsKey('Task') -and $Config.Task.ContainsKey('MaxAttempts')){$maxAttempts=[Math]::Max(1,[int]$Config.Task.MaxAttempts)}
    $initialStartSpacingSeconds=Get-FsWorkerStartSpacingSeconds -Config $Config -Stage $Stage

    Write-Host ("        [WORKER] {0} Hintergrund-Worker für '{1}' werden gestartet; max. {2} Neustart(e) je Slot ..." -f $workerTarget,$Stage,$maxRestarts) -ForegroundColor DarkGray
    if($initialStartSpacingSeconds -gt 0){
        Write-Host ("        [WORKER] Initialer Startabstand: {0}s zwischen den Worker-Jobs." -f $initialStartSpacingSeconds) -ForegroundColor DarkGray
    }
    Write-Host ("        [WORKER] Skript: {0}; Programmverzeichnis: {1}" -f $WorkerPath,$applicationRoot) -ForegroundColor DarkGray

    for($slot=1;$slot -le $workerTarget;$slot++){
        $restartCounts[$slot]=0
        if($slot -gt 1 -and $initialStartSpacingSeconds -gt 0){
            Write-Host ("        [WORKER] Slot {0} startet in {1}s ..." -f $slot,$initialStartSpacingSeconds) -ForegroundColor DarkGray
            Start-Sleep -Seconds $initialStartSpacingSeconds
        }
        $job=Start-FsStageWorkerJob -WorkerPath $WorkerPath -Stage $Stage -ProjectId $ProjectId -RunId $RunId -Workspace $Workspace -SqlitePath $SqlitePath -ConfigJson $configJson -ApplicationRoot $applicationRoot -Slot $slot -Restart 0
        [void]$jobs.Add($job)
        Write-Host ("        [WORKER] {0} angelegt (Job-ID {1})" -f $job.Name,$job.Id) -ForegroundColor DarkGray
    }

    $clock=[Diagnostics.Stopwatch]::StartNew()
    $lastTextAt=[DateTime]::MinValue
    $lastChangeAt=[DateTime]::UtcNow
    $lastSignature=''
    $lastRateTerminal=0
    $lastRateSeconds=0.0
    $lastStallWarningAt=[DateTime]::MinValue
    $lastReaperAt=[DateTime]::MinValue
    $printedJobErrors=@{}
    $workerFailures=0
    $abortReason=$null
    $rateSamples=New-Object Collections.Queue
    $initialCounts=Get-FsStageCounts -SqlitePath $SqlitePath -DatabasePath $databasePath -ProjectId $ProjectId -Stage $Stage -MaxAttempts $maxAttempts
    $initialSuccessful=[int]$initialCounts.done+[int]$initialCounts.reused
    $initialTerminal=$initialSuccessful+[int]$initialCounts.failed+[int]$initialCounts.skipped
    $rateSamples.Enqueue([pscustomobject]@{At=[DateTime]::UtcNow;Terminal=$initialTerminal})
    $lastTuneStatus=$null
    $lastTuneReadAt=[DateTime]::MinValue
    $lastTunePersistAt=[DateTime]::MinValue
    $lastTuneLiveSampleAt=[DateTime]::MinValue
    $lastTuneErrorAt=[DateTime]::MinValue
    $tuneWindowBaseDone=[int]$initialCounts.done
    $tuneWindowBaseBytes=[long]0
    $tuneWindowStartedAt=[DateTime]::UtcNow
    $tuneObservedDelay=$null
    $tuneObserved429=0
    $downloadAutoTuneEnabled=($Stage -eq 'download' -and (Test-FsDownloadAutoTuneEnabled -Config $Config))
    $sessionBaseTerminal=$initialTerminal
    $sessionBaseDone=[int]$initialCounts.done
    $sessionBaseReused=[int]$initialCounts.reused
    if($Stage -eq 'download' -and $downloadAutoTuneEnabled){
        try{
            $lastTuneStatus=Get-FsDownloadAutoTuneStatus -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $databasePath
            if($null -ne $lastTuneStatus){
                # The tuning row is initialized before DOWNLOAD-SEED and therefore
                # represents the complete run/session baseline, including reuse
                # decisions made during seeding.
                $sessionBaseTerminal=[int]$lastTuneStatus.RunStartTerminal
                $sessionBaseDone=[int]$lastTuneStatus.RunStartDone
                $sessionBaseReused=[int]$lastTuneStatus.RunStartReused
            }
            if($null -ne $lastTuneStatus -and [bool]$lastTuneStatus.Enabled){
                $tuneWindowBaseBytes=Get-FsDownloadDoneBytes -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $databasePath
                $tuneObservedDelay=[int]$lastTuneStatus.CurrentDelayMs
                $tuneObserved429=[int]$lastTuneStatus.Total429
            }
        }catch{
            $lastTuneStatus=$null
        }
    }

    try {
        while($true){
            foreach($job in @($jobs)){
                $receiveErrors=@();$receiveWarnings=@()
                $output=@(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable +receiveErrors -WarningVariable +receiveWarnings)
                foreach($line in $output){if($null -ne $line -and -not[string]::IsNullOrWhiteSpace([string]$line)){Write-Host ("        {0}" -f [string]$line) -ForegroundColor DarkGray}}
                foreach($warning in $receiveWarnings){Write-Warning ("Worker {0}: {1}" -f $job.Name,[string]$warning)}
                foreach($errorRecord in $receiveErrors){$key="{0}|{1}" -f $job.Id,[string]$errorRecord;if(-not$printedJobErrors.ContainsKey($key)){$printedJobErrors[$key]=$true;Write-Warning ("Worker {0}: {1}" -f $job.Name,[string]$errorRecord)}}
            }

            if(([DateTime]::UtcNow-$lastReaperAt).TotalSeconds -ge 30){
                try{Reset-FsExpiredTasks -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $databasePath -Stage $Stage}
                catch{Write-Warning ("Lease-Reaper vorübergehend nicht ausführbar: {0}" -f $_.Exception.Message)}
                $lastReaperAt=[DateTime]::UtcNow
            }

            foreach($job in @($jobs | Where-Object { $_.State -notin @('Running','NotStarted') -and -not $_.FsHandled })){
                $job.FsHandled=$true
                try{Reset-FsWorkerTasks -ProjectId $ProjectId -Worker $job.Name -SqlitePath $SqlitePath -DatabasePath $databasePath -Reason ("Workerzustand {0}; Task erneut eingereiht." -f $job.State) -Stage $Stage}
                catch{Write-Warning ("Tasks von Worker {0} konnten noch nicht freigegeben werden: {1}" -f $job.Name,$_.Exception.Message)}
                if($job.State -ne 'Completed'){
                    $workerFailures++
                    $reason=$null
                    if($job.ChildJobs.Count -gt 0){$reason=$job.ChildJobs[0].JobStateInfo.Reason}
                    if($null -ne $reason){Write-Warning ("Worker {0} fehlgeschlagen: {1}" -f $job.Name,$reason.Message)}else{Write-Warning ("Worker {0} endete mit Zustand {1}." -f $job.Name,$job.State)}
                }
            }

            $counts=Get-FsStageCounts -SqlitePath $SqlitePath -DatabasePath $databasePath -ProjectId $ProjectId -Stage $Stage -MaxAttempts $maxAttempts
            $activeJobs=@($jobs|Where-Object{$_.State -in @('Running','NotStarted')})
            $activeSlots=@{};foreach($job in $activeJobs){$activeSlots[[int]$job.FsSlot]=$true}
            $workerRestarted=$false

            if(([int]$counts.pending+[int]$counts.retryable) -gt 0 -and $activeJobs.Count -lt $workerTarget){
                for($slot=1;$slot -le $workerTarget;$slot++){
                    if($activeSlots.ContainsKey($slot)){continue}
                    if([int]$restartCounts[$slot] -ge $maxRestarts){continue}
                    $restartCounts[$slot]=[int]$restartCounts[$slot]+1
                    $replacement=Start-FsStageWorkerJob -WorkerPath $WorkerPath -Stage $Stage -ProjectId $ProjectId -RunId $RunId -Workspace $Workspace -SqlitePath $SqlitePath -ConfigJson $configJson -ApplicationRoot $applicationRoot -Slot $slot -Restart ([int]$restartCounts[$slot])
                    [void]$jobs.Add($replacement);$activeSlots[$slot]=$true;$workerRestarted=$true
                    Write-Warning ("Worker-Slot {0} wird als {1} neu gestartet (Versuch {2}/{3})." -f $slot,$replacement.Name,$restartCounts[$slot],$maxRestarts)
                }
                $activeJobs=@($jobs|Where-Object{$_.State -in @('Running','NotStarted')})
            }

            # The old loop queried the same aggregate twice on every poll. A
            # second read is only required when a replacement worker actually
            # claimed or released work between both points.
            if($workerRestarted){
                $counts=Get-FsStageCounts -SqlitePath $SqlitePath -DatabasePath $databasePath -ProjectId $ProjectId -Stage $Stage -MaxAttempts $maxAttempts
            }
            $total=[int]$counts.pending+[int]$counts.running+[int]$counts.done+[int]$counts.retryable+[int]$counts.failed+[int]$counts.skipped+[int]$counts.reused
            $successful=[int]$counts.done+[int]$counts.reused
            $terminal=$successful+[int]$counts.failed+[int]$counts.skipped
            $unfinished=[int]$counts.pending+[int]$counts.running+[int]$counts.retryable
            $activeJobs=@($jobs|Where-Object{$_.State -in @('Running','NotStarted')})

            $signature="{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f $counts.pending,$counts.running,$counts.done,$counts.retryable,$counts.failed,$counts.skipped,$counts.reused
            if($signature -ne $lastSignature){$lastSignature=$signature;$lastChangeAt=[DateTime]::UtcNow}

            if($unfinished -eq 0 -and $activeJobs.Count -eq 0){break}
            if($unfinished -gt 0 -and $activeJobs.Count -eq 0){
                $abortReason="Keine Worker mehr aktiv; $unfinished Aufgabe(n) sind weiterhin pending/running. Neustartlimit je Slot: $maxRestarts."
                break
            }

            $elapsedSeconds=[Math]::Max(0.001,$clock.Elapsed.TotalSeconds)
            $sampleNow=[DateTime]::UtcNow
            $rateSamples.Enqueue([pscustomobject]@{At=$sampleNow;Terminal=$terminal})
            $oldestRateSample=[pscustomobject]$rateSamples.Peek()
            while($rateSamples.Count -gt 2 -and ($sampleNow-$oldestRateSample.At).TotalSeconds -gt 600){
                [void]$rateSamples.Dequeue()
                $oldestRateSample=[pscustomobject]$rateSamples.Peek()
            }
            $rateBase=$oldestRateSample
            $rateSeconds=[Math]::Max(0.0,($sampleNow-$rateBase.At).TotalSeconds)
            $rate=if($rateSeconds -ge 10){($terminal-[int]$rateBase.Terminal)/$rateSeconds}else{0.0}
            if($rate -lt 0){$rate=0.0}
            $remainingSeconds=$null
            $remainingText='--:--'
            $completionAt=$null
            $completionText='--'
            if($unfinished -eq 0){
                $remainingSeconds=0.0;$remainingText='00:00';$completionAt=[DateTime]::Now;$completionText=Format-FsStageCompletionTime $completionAt
            }elseif($rate -gt 0){
                $remainingSeconds=$unfinished/$rate
                $remainingText=Format-FsStageDuration $remainingSeconds
                $completionAt=[DateTime]::Now.AddSeconds($remainingSeconds)
                $completionText=Format-FsStageCompletionTime $completionAt
            }
            $percent=if($total -gt 0){[Math]::Min(100,[Math]::Round($terminal*100.0/$total,1))}else{100}
            $workerStates=@($jobs|Group-Object State|ForEach-Object{"{0}={1}" -f $_.Name,$_.Count}) -join ', '
            $idleText=Format-FsStageDuration (([DateTime]::UtcNow-$lastChangeAt).TotalSeconds)

            $sessionProcessed=[Math]::Max(0,$terminal-$sessionBaseTerminal)
            $sessionDone=[Math]::Max(0,[int]$counts.done-$sessionBaseDone)
            $sessionReused=[Math]::Max(0,[int]$counts.reused-$sessionBaseReused)
            $sessionFailed=[Math]::Max(0,[int]$counts.failed-[int]$initialCounts.failed)
            $sessionSkipped=[Math]::Max(0,[int]$counts.skipped-[int]$initialCounts.skipped)

            # HF31: one central controller derives successful download windows
            # from committed task counts. Workers only read the shared delay and
            # report rare HTTP 429 events. This removes one SQLite transaction
            # per file and makes the measured session/window counts observable.
            # HF50: the controller still reads committed counts every 10 seconds, but
            # persists the live tuning row only every 30 seconds and chart samples
            # every 60 seconds. A complete window is always committed immediately.
            if($Stage -eq 'download' -and $downloadAutoTuneEnabled -and ($sampleNow-$lastTuneReadAt).TotalSeconds -ge 10){
                try{
                    $freshTune=Get-FsDownloadAutoTuneStatus -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $databasePath
                    if($null -ne $freshTune -and [bool]$freshTune.Enabled){
                        $currentDoneBytes=Get-FsDownloadDoneBytes -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $databasePath
                        if($null -eq $tuneObservedDelay){
                            $tuneObservedDelay=[int]$freshTune.CurrentDelayMs
                            $tuneObserved429=[int]$freshTune.Total429
                            $tuneWindowBaseDone=[int]$counts.done
                            $tuneWindowBaseBytes=[long]$currentDoneBytes
                            $tuneWindowStartedAt=$sampleNow
                        }elseif([int]$freshTune.CurrentDelayMs -ne [int]$tuneObservedDelay){
                            # A completed window or a new 429 burst changed the
                            # active delay and starts one clean measurement window.
                            # Additional 429 responses from the same burst do not
                            # repeatedly discard progress.
                            $tuneObservedDelay=[int]$freshTune.CurrentDelayMs
                            $tuneObserved429=[int]$freshTune.Total429
                            $tuneWindowBaseDone=[int]$counts.done
                            $tuneWindowBaseBytes=[long]$currentDoneBytes
                            $tuneWindowStartedAt=$sampleNow
                        }elseif([int]$freshTune.Total429 -ne [int]$tuneObserved429){
                            # Every newly observed 429 restarts the recovery counter.
                            # The burst number does not change, but the required 8
                            # successful files must occur after the latest 429.
                            $tuneObserved429=[int]$freshTune.Total429
                            $tuneWindowBaseDone=[int]$counts.done
                            $tuneWindowBaseBytes=[long]$currentDoneBytes
                            $tuneWindowStartedAt=$sampleNow
                        }

                        $windowSuccesses=[Math]::Max(0,[int]$counts.done-$tuneWindowBaseDone)
                        $windowBytes=[Math]::Max([long]0,[long]$currentDoneBytes-$tuneWindowBaseBytes)
                        $windowElapsedMs=[Math]::Max([long]1,[long](($sampleNow-$tuneWindowStartedAt).TotalMilliseconds))
                        if($windowSuccesses -ge [int]$freshTune.WindowTarget -and -not[bool]$freshTune.BurstOpen){
                            $freshTune=Complete-FsDownloadAutoTuneWindow -ProjectId $ProjectId -RunId $RunId -Config $Config -SqlitePath $SqlitePath -DatabasePath $databasePath -Successes $windowSuccesses -Bytes $windowBytes -ElapsedMs $windowElapsedMs
                            $tuneWindowBaseDone=[int]$counts.done
                            $tuneWindowBaseBytes=[long]$currentDoneBytes
                            $tuneWindowStartedAt=$sampleNow
                            $tuneObservedDelay=[int]$freshTune.CurrentDelayMs
                            $tuneObserved429=[int]$freshTune.Total429
                            $lastTunePersistAt=$sampleNow
                            $lastTuneLiveSampleAt=$sampleNow
                        }elseif(($sampleNow-$lastTunePersistAt).TotalSeconds -ge 30){
                            $writeLive=(($sampleNow-$lastTuneLiveSampleAt).TotalSeconds -ge 60)
                            $freshTune=Update-FsDownloadAutoTuneProgress -ProjectId $ProjectId -RunId $RunId -Config $Config -SqlitePath $SqlitePath -DatabasePath $databasePath -Successes $windowSuccesses -Bytes $windowBytes -ElapsedMs $windowElapsedMs -WriteLiveSample:$writeLive
                            $lastTunePersistAt=$sampleNow
                            if($writeLive){$lastTuneLiveSampleAt=$sampleNow}
                        }
                    }
                    $lastTuneStatus=$freshTune
                }catch{
                    if(($sampleNow-$lastTuneErrorAt).TotalSeconds -ge 60){
                        Write-Warning ("Anfragesteuerung vorübergehend nicht aktualisierbar: {0}" -f $_.Exception.Message)
                        $lastTuneErrorAt=$sampleNow
                    }
                }
                $lastTuneReadAt=$sampleNow
            }

            $requestControl=''
            if($Stage -eq 'download' -and $null -ne $lastTuneStatus -and [bool]$lastTuneStatus.Enabled){
                $currentDelay=[Math]::Max(0,[int]$lastTuneStatus.CurrentDelayMs)
                $remainingInWindow=[Math]::Max(0,[int]$lastTuneStatus.WindowTarget-[int]$lastTuneStatus.WindowSuccesses)
                $cooldownRemaining=if([long]$lastTuneStatus.CooldownUntilMs -gt 0){[Math]::Max(0,[int][Math]::Ceiling(([long]$lastTuneStatus.CooldownUntilMs-(Get-FsUnixMilliseconds))/1000.0))}else{0}
                if($cooldownRemaining -gt 0){
                    $requestControl=("429-Pause noch {0}s; danach einmalig 3s gestaffelter Start bei {1} ms" -f $cooldownRemaining,$currentDelay)
                }elseif([bool]$lastTuneStatus.BurstOpen){
                    $recovery=Get-FsDownloadBurstRecoverySettings -Config $Config
                    $successesRemaining=[Math]::Max(0,[int]$recovery.Successes-[int]$lastTuneStatus.WindowSuccesses)
                    $quietRemaining=if([long]$lastTuneStatus.Last429AtMs -gt 0){[Math]::Max(0,[int][Math]::Ceiling([double]$recovery.Seconds-((Get-FsUnixMilliseconds)-[long]$lastTuneStatus.Last429AtMs)/1000.0))}else{[int]$recovery.Seconds}
                    $requestControl=("Stabilisierung nach 429: noch {0} Erfolge / {1}s ohne neue 429" -f $successesRemaining,$quietRemaining)
                }elseif($currentDelay -gt 0){
                    $decrease=[Math]::Min(100,[Math]::Max(20,[int][Math]::Ceiling($currentDelay*0.10)))
                    $requestControl=("Anfrageabstand {0} ms; ohne 429 nach {1} Dateien -> {2} ms" -f $currentDelay,$remainingInWindow,[Math]::Max(0,$currentDelay-$decrease))
                }else{
                    $requestControl='Anfrageabstand 0 ms; keine künstliche Wartezeit'
                }
            }
            if($Stage -eq 'download'){
                # Three immediately understandable lines for users who do not
                # know FindSeries internals: what is happening, how far it is,
                # and when it will probably finish. Technical tuning details stay
                # in the text log and monitor instead of crowding the progress bar.
                $activityText='Bilder herunterladen – läuft'
                $status=("{0:N0} von {1:N0} Dateien verarbeitet ({2:N1} %) – noch {3:N0}" -f $terminal,$total,$percent,$unfinished)
                $currentOperation=("{0} aktiv | {1:N2} Dateien/s | fertig ca. {2} | dieser Lauf: {3:N0} neu, {4:N0} vorhanden, {5:N0} Fehler{6}" -f $counts.running,$rate,$completionText,$sessionDone,$sessionReused,$sessionFailed,$(if([string]::IsNullOrWhiteSpace($requestControl)){''}else{" | $requestControl"}))
            }else{
                $status=("Fortschritt: {0:N0} von {1:N0} Aufgaben erledigt ({2:N1} %) | Noch {3:N0} | Aktiv {4} | Fehler {5}" -f $terminal,$total,$percent,$unfinished,$counts.running,$counts.failed)
                $currentOperation=("Dieser Lauf: {0:N0} bearbeitet | Tempo {1:N2} Aufgabe(n)/s | Restzeit {2} | Ende ca. {3}" -f $sessionProcessed,$rate,$remainingText,$completionText)
                $activityText=("FindSeries: {0}" -f $Stage)
            }
            Write-Progress -Activity $activityText -Status $status -CurrentOperation $currentOperation -PercentComplete $percent

            if(([DateTime]::UtcNow-$lastTextAt).TotalSeconds -ge [Math]::Max(5,$TextProgressSeconds)){
                Write-Host ("        [{0}] {1:N1} % abgeschlossen: {2:N0} von {3:N0} Aufgaben; noch {4:N0}; {5} aktiv; {6} Fehler." -f $Stage.ToUpperInvariant(),$percent,$terminal,$total,$unfinished,$counts.running,$counts.failed) -ForegroundColor DarkGray
                Write-Host ("                 Dieser Lauf: {0:N0} bearbeitet ({1:N0} neu, {2:N0} bereits vorhanden, {3:N0} Fehler, {4:N0} übersprungen)." -f $sessionProcessed,$sessionDone,$sessionReused,$sessionFailed,$sessionSkipped) -ForegroundColor DarkGray
                Write-Host ("                 Tempo {0:N2} Aufgabe(n)/s | Restzeit {1} | voraussichtlich fertig {2} | Laufzeit {3}." -f $rate,$remainingText,$completionText,(Format-FsStageDuration $elapsedSeconds)) -ForegroundColor DarkGray
                if($Stage -eq 'download' -and $null -ne $lastTuneStatus -and [bool]$lastTuneStatus.Enabled){
                    $windowMBps=[double]$lastTuneStatus.WindowBytesPerSecond/1MB
                    $currentDelay=[Math]::Max(0,[int]$lastTuneStatus.CurrentDelayMs)
                    $remainingInWindow=[Math]::Max(0,[int]$lastTuneStatus.WindowTarget-[int]$lastTuneStatus.WindowSuccesses)
                    $cooldownRemaining=if([long]$lastTuneStatus.CooldownUntilMs -gt 0){[Math]::Max(0,[int][Math]::Ceiling(([long]$lastTuneStatus.CooldownUntilMs-(Get-FsUnixMilliseconds))/1000.0))}else{0}
                    if($cooldownRemaining -gt 0){
                        $controlText=("Gemeinsame HTTP-429-Pause noch ca. {0}s; danach einmalig 3s gestaffelter Wiederanlauf bei {1} ms." -f $cooldownRemaining,$currentDelay)
                    }elseif([bool]$lastTuneStatus.BurstOpen){
                        $recovery=Get-FsDownloadBurstRecoverySettings -Config $Config
                        $successesRemaining=[Math]::Max(0,[int]$recovery.Successes-[int]$lastTuneStatus.WindowSuccesses)
                        $quietRemaining=if([long]$lastTuneStatus.Last429AtMs -gt 0){[Math]::Max(0,[int][Math]::Ceiling([double]$recovery.Seconds-((Get-FsUnixMilliseconds)-[long]$lastTuneStatus.Last429AtMs)/1000.0))}else{[int]$recovery.Seconds}
                        $controlText=("Anfrageabstand {0} ms; Stabilisierung nach 429: noch {1} erfolgreiche Dateien und {2}s ohne neue 429." -f $currentDelay,$successesRemaining,$quietRemaining)
                    }elseif($currentDelay -gt 0){
                        $decrease=[Math]::Min(100,[Math]::Max(20,[int][Math]::Ceiling($currentDelay*0.10)))
                        $controlText=("Anfrageabstand {0} ms; ohne HTTP 429 nach noch {1} erfolgreichen Dateien -> {2} ms." -f $currentDelay,$remainingInWindow,[Math]::Max(0,$currentDelay-$decrease))
                    }else{
                        $controlText='Anfrageabstand 0 ms; keine zusätzliche künstliche Wartezeit.'
                    }
                    Write-Host ("                 [ANFRAGESTEUERUNG] {0} | 429-Antworten: {1} | 429-Bursts: {2}" -f $controlText,$lastTuneStatus.Total429,$lastTuneStatus.ThrottleBursts) -ForegroundColor DarkCyan
                    Write-Host ("                                      Messung (nur Information): Fenster {0}/{1} | {2:N2} Dateien/s | {3:N2} MB/s." -f $lastTuneStatus.WindowSuccesses,$lastTuneStatus.WindowTarget,$lastTuneStatus.WindowFilesPerSecond,$windowMBps) -ForegroundColor DarkCyan
                    if([bool]$lastTuneStatus.HasCompletedWindow){
                        Write-Host ("                                      Letztes vollständiges Fenster: {0} ms | {1} Dateien in {2} | {3:N2} Dateien/s | {4:N2} MB/s." -f $lastTuneStatus.LastWindowDelayMs,$lastTuneStatus.LastWindowSuccesses,(Format-FsStageDuration ([double]$lastTuneStatus.LastWindowElapsedMs/1000.0)),$lastTuneStatus.LastWindowFilesPerSecond,([double]$lastTuneStatus.LastWindowBytesPerSecond/1MB)) -ForegroundColor DarkCyan
                    }
                    Write-Host ("                                      Letzte Regelentscheidung: {0}" -f $lastTuneStatus.LastChangeReason) -ForegroundColor DarkCyan
                }
                try{
                    $runningDetails=@(Get-FsStageRunningDetails -SqlitePath $SqlitePath -DatabasePath $databasePath -ProjectId $ProjectId -Stage $Stage)
                    foreach($detail in $runningDetails){$detailParts=New-Object Collections.Generic.List[string];foreach($property in $detail.PSObject.Properties){if($property.Name -eq 'item'){continue};if($null -ne $property.Value -and -not[string]::IsNullOrWhiteSpace([string]$property.Value)){$detailParts.Add(("{0}={1}" -f $property.Name,$property.Value))}};Write-Host ("                 aktiv: {0}{1}" -f ([string]$detail.item),$(if($detailParts.Count){" | "+($detailParts -join '; ')}else{''})) -ForegroundColor DarkGray}
                }catch{Write-Host ("                 Detailstatus nicht lesbar: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow}
                $idleSeconds=([DateTime]::UtcNow-$lastChangeAt).TotalSeconds
                if($idleSeconds -ge [Math]::Max(15,$StallWarningSeconds) -and $unfinished -gt 0 -and ([DateTime]::UtcNow-$lastStallWarningAt).TotalSeconds -ge [Math]::Max(15,$StallWarningSeconds)){
                    Write-Warning (("Stufe '{0}': seit {1} keine Statusänderung; pending {2}, retryfähig {3}, running {4}; Jobzustände: {5}" -f $Stage,$idleText,$counts.pending,$counts.retryable,$counts.running,$workerStates))
                    $lastStallWarningAt=[DateTime]::UtcNow
                }
                $lastTextAt=[DateTime]::UtcNow
            }
            Start-Sleep -Seconds ([Math]::Max(1,$PollSeconds))
        }
    }
    finally{
        Write-Progress -Activity $(if($Stage -eq 'download'){'Bilder herunterladen – läuft'}else{"FindSeries: $Stage"}) -Completed
        foreach($job in @($jobs)){
            if($job.State -in @('Running','NotStarted')){Stop-Job -Job $job -ErrorAction SilentlyContinue}
            try{Receive-Job -Job $job -ErrorAction SilentlyContinue|ForEach-Object{if($null -ne $_ -and -not[string]::IsNullOrWhiteSpace([string]$_)){Write-Host ("        {0}" -f [string]$_) -ForegroundColor DarkGray}}}catch{}
            try{Reset-FsWorkerTasks -ProjectId $ProjectId -Worker $job.Name -SqlitePath $SqlitePath -DatabasePath $databasePath -Reason 'Stufensteuerung beendet; Task erneut eingereiht.' -Stage $Stage}catch{}
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    $final=Get-FsStageCounts -SqlitePath $SqlitePath -DatabasePath $databasePath -ProjectId $ProjectId -Stage $Stage -MaxAttempts $maxAttempts
    $finalTotal=[int]$final.pending+[int]$final.running+[int]$final.done+[int]$final.retryable+[int]$final.failed+[int]$final.skipped+[int]$final.reused
    $finalSuccessful=[int]$final.done+[int]$final.reused
    $finalTerminal=$finalSuccessful+[int]$final.failed+[int]$final.skipped
    $unfinished=[int]$final.pending+[int]$final.running+[int]$final.retryable
    Write-Host ("        [{0}] beendet: abgeschlossen {1}/{2}; erfolgreich {3}; pending {4}; retryfähig {5}; running {6}; endgültig failed {7}; skipped {8}; reused {9}; Workerfehler {10}; Laufzeit {11}" -f $Stage.ToUpperInvariant(),$finalTerminal,$finalTotal,$finalSuccessful,$final.pending,$final.retryable,$final.running,$final.failed,$final.skipped,$final.reused,$workerFailures,(Format-FsStageDuration $clock.Elapsed.TotalSeconds)) -ForegroundColor DarkGray

    if(-not[string]::IsNullOrWhiteSpace($abortReason)){throw "Stufe '$Stage' kontrolliert abgebrochen: $abortReason"}
    if($unfinished -gt 0){throw "Stufe '$Stage' wurde nicht vollständig verarbeitet: $unfinished Aufgabe(n) pending/retryfähig/running."}
    if([int]$final.failed -gt 0){Write-Warning "$($final.failed) Aufgaben in Stufe '$Stage' sind nach den vorgesehenen Versuchen fehlgeschlagen. Details: Get-FindSeriesStatus.ps1 -ProjectId $ProjectId -Errors"}
    if($workerFailures -gt 0){Write-Warning "$workerFailures Workerfehler in Stufe '$Stage' wurden durch Task-Freigabe und Worker-Neustart aufgefangen."}
    return $final
}

Export-ModuleMember -Function *-Fs*
