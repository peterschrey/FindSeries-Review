Set-StrictMode -Version 2.0

function Get-FsHttpStatusCode {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.Exception.Response.StatusCode) { return [int]$ErrorRecord.Exception.Response.StatusCode }
    }
    catch {}
    return $null
}

function Get-FsRetryAfterSeconds {
    param($ErrorRecord)
    try {
        $header = $ErrorRecord.Exception.Response.Headers['Retry-After']
        if ($header) {
            $seconds = 0
            if ([int]::TryParse([string]$header,[ref]$seconds)) { return [Math]::Max(1,$seconds) }
            $date = [DateTime]::MinValue
            if ([DateTime]::TryParse([string]$header,[ref]$date)) {
                return [Math]::Max(1,[int][Math]::Ceiling(($date.ToUniversalTime()-[DateTime]::UtcNow).TotalSeconds))
            }
        }
    }
    catch {}
    return $null
}

function Get-FsPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default=$null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $value=$Object[$Name]
            if ($null -ne $value) { return $value }
        }
        return $Default
    }
    $property=$Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Invoke-FsWikiApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BaseUri,
        [Parameter(Mandatory=$true)][hashtable]$Parameters,
        [Parameter(Mandatory=$true)][string]$GateName,
        [Parameter(Mandatory=$true)][string]$SqlitePath,
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [int]$DelayMs=750,
        [int]$Retries=8,
        [hashtable]$Headers=@{},
        [Nullable[int]]$ProjectId,
        [Nullable[int]]$RunId,
        [string]$Stage='api',
        [scriptblock]$Heartbeat
    )
    if (-not $Parameters.ContainsKey('format')) { $Parameters.format='json' }
    if (-not $Parameters.ContainsKey('formatversion')) { $Parameters.formatversion=2 }
    $apiErrorCode = $null
    $effectiveDelayMs=[Math]::Max(0,$DelayMs)
    $apiAction=if($Parameters.ContainsKey('action')){[string]$Parameters.action}else{'request'}
    $apiModule=$null
    foreach($moduleKey in @('list','generator','prop','meta')){if($Parameters.ContainsKey($moduleKey)){$apiModule=[string]$Parameters[$moduleKey];break}}
    $profileOperation=if([string]::IsNullOrWhiteSpace($apiModule)){"${GateName}:${apiAction}"}else{"${GateName}:${apiAction}/${apiModule}"}
    for ($attempt=1; $attempt -le $Retries; $attempt++) {
        $profileAttemptWatch=[Diagnostics.Stopwatch]::StartNew();$profileGateMs=0.0;$profileHttpMs=0.0
        try {
            if ($null -ne $Heartbeat) { & $Heartbeat }
            $profileGateWatch=[Diagnostics.Stopwatch]::StartNew()
            $slotInfo=Acquire-FsApiSlot -SqlitePath $SqlitePath -DatabasePath $DatabasePath -GateName $GateName -DelayMs $effectiveDelayMs
            $profileGateMs=$profileGateWatch.Elapsed.TotalMilliseconds
            if ($null -ne $Heartbeat) { & $Heartbeat }
            $profileHttpWatch=[Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-RestMethod -Uri $BaseUri -Method Get -Body $Parameters -Headers $Headers -TimeoutSec 120 -ErrorAction Stop
            $profileHttpMs=$profileHttpWatch.Elapsed.TotalMilliseconds
            if ($null -eq $response) { throw 'Die Wikimedia-API hat eine leere Antwort geliefert.' }
            $apiError=Get-FsPropertyValue -Object $response -Name 'error'
            if ($null -ne $apiError) {
                $apiErrorCode=[string](Get-FsPropertyValue -Object $apiError -Name 'code' -Default 'unknown')
                $apiErrorInfo=[string](Get-FsPropertyValue -Object $apiError -Name 'info' -Default 'Keine Fehlerbeschreibung geliefert.')
                throw "API-Fehler ${apiErrorCode}: $apiErrorInfo"
            }
            if ($null -ne $Heartbeat) { & $Heartbeat }
            $timing=[pscustomobject]@{GateMs=[Math]::Round($profileGateMs,3);HttpParseMs=[Math]::Round($profileHttpMs,3);TotalMs=[Math]::Round($profileAttemptWatch.Elapsed.TotalMilliseconds,3);Attempt=$attempt}
            try{$response|Add-Member -NotePropertyName '__fs_profile' -NotePropertyValue $timing -Force}catch{}
            if(Test-FsDiagnosticsEnabled){Write-FsPerformanceRecord -Record @{record_type='api';operation=$profileOperation;query_text=$(if($Parameters.ContainsKey('srsearch')){[string]$Parameters.srsearch}else{$null});language=$(if($Parameters.ContainsKey('uselang')){[string]$Parameters.uselang}else{$null});attempt=$attempt;gate_ms=$timing.GateMs;http_parse_ms=$timing.HttpParseMs;total_ms=$timing.TotalMs;success=$true}}
            return $response
        }
        catch {
            if(Test-FsDiagnosticsEnabled){Write-FsPerformanceRecord -Record @{record_type='api';operation=$profileOperation;query_text=$(if($Parameters.ContainsKey('srsearch')){[string]$Parameters.srsearch}else{$null});attempt=$attempt;gate_ms=[Math]::Round($profileGateMs,3);http_parse_ms=[Math]::Round($profileHttpMs,3);total_ms=[Math]::Round($profileAttemptWatch.Elapsed.TotalMilliseconds,3);success=$false;error=$_.Exception.Message}}
            $message=[string]$_.Exception.Message
            if ($message -like 'SQLite-Fehler:*' -or $message -like 'Task-Lease*' -or $message -like 'Run *ist nicht mehr aktiv*') { throw }
            $status = Get-FsHttpStatusCode $_
            $retryAfter = Get-FsRetryAfterSeconds $_
            $isPermanent = (-not [string]::IsNullOrWhiteSpace($apiErrorCode)) -and (
                $apiErrorCode -like 'invalid*' -or $apiErrorCode -in @('badtitle','missingtitle','notitle','badvalue','invalidparammix','paramvalidator')
            )
            # HTTP 414 is determined solely by the already constructed URI.
            # Retrying the identical GET request can never succeed and used to
            # keep a metadata worker occupied for more than twenty minutes.
            # Let the metadata layer split the request immediately instead.
            $isUriTooLong = ($status -eq 414 -or $message -match '(?i)\(414\)|URI Too Long|Request-URI Too Large')
            $effectiveRetries = if ($isUriTooLong) { 1 } elseif ($isPermanent) { [Math]::Min(2,$Retries) } else { $Retries }
            if ($attempt -ge $effectiveRetries) {
                try { Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -Stage $Stage -Level 'error' -Message $message -Details @{ status=$status; api_code=$apiErrorCode; parameters=$Parameters } } catch {}
                throw
            }
            $delay = if ($isPermanent) { 15 } elseif ($status -eq 429 -or $retryAfter) { [Math]::Max(60,[Math]::Min(300,([Math]::Max([int]$retryAfter,15*$attempt))*2)) } else { [Math]::Min(60,[Math]::Pow(2,$attempt)) }
            $globalCooldown = ($status -eq 429 -or $null -ne $retryAfter)
            if ($globalCooldown) {
                [void](Set-FsApiCooldown -SqlitePath $SqlitePath -DatabasePath $DatabasePath -GateName $GateName -Seconds $delay -BaseDelayMs $effectiveDelayMs)
            }
            $retryMessage = if ($globalCooldown) {
                "API-Retry $attempt/$effectiveRetries nach globalem ${delay}s-Cooldown: $message"
            } else {
                "API-Retry $attempt/$effectiveRetries in ${delay}s: $message"
            }
            try { Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -Stage $Stage -Level 'warning' -Message $retryMessage -Details @{ status=$status; api_code=$apiErrorCode; global_cooldown=$globalCooldown } } catch {}
            if ($null -ne $Heartbeat) { & $Heartbeat }
            if (-not $globalCooldown) { Start-Sleep -Seconds $delay }
            $apiErrorCode = $null
        }
    }
}

function Invoke-FsCommonsApi {
    param(
        [hashtable]$Parameters,[string]$SqlitePath,[string]$DatabasePath,[int]$DelayMs,[int]$Retries,
        [hashtable]$Headers,[Nullable[int]]$ProjectId,[Nullable[int]]$RunId,[string]$Stage='commons',[scriptblock]$Heartbeat
    )
    return Invoke-FsWikiApi -BaseUri 'https://commons.wikimedia.org/w/api.php' -Parameters $Parameters -GateName 'commons' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs $DelayMs -Retries $Retries -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage $Stage -Heartbeat $Heartbeat
}

function Invoke-FsWikidataApi {
    param(
        [hashtable]$Parameters,[string]$SqlitePath,[string]$DatabasePath,[int]$DelayMs,[int]$Retries,
        [hashtable]$Headers,[Nullable[int]]$ProjectId,[Nullable[int]]$RunId,[string]$Stage='wikidata',[scriptblock]$Heartbeat
    )
    return Invoke-FsWikiApi -BaseUri 'https://www.wikidata.org/w/api.php' -Parameters $Parameters -GateName 'wikidata' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs $DelayMs -Retries $Retries -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage $Stage -Heartbeat $Heartbeat
}

function Normalize-FsFileTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $value = $Title.Trim().Replace('_',' ')
    if ($value -notmatch '^(?i)File:') { $value='File:'+$value }
    return 'File:' + $value.Substring(5).Trim()
}

function Normalize-FsCategoryTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $value=$Title.Trim().Replace('_',' ')
    if ($value -notmatch '^(?i)Category:') { $value='Category:'+$value }
    return 'Category:'+$value.Substring(9).Trim()
}

function ConvertTo-FsPlainText {
    param($Value)
    if ($null -eq $Value) { return $null }
    $text=[string]$Value
    $text=[Net.WebUtility]::HtmlDecode($text)
    $text=[regex]::Replace($text,'<[^>]+>',' ')
    $text=[regex]::Replace($text,'\{\{[^{}]*\}\}',' ')
    $text=[regex]::Replace($text,'\[\[(?:[^\]|]+\|)?([^\]]+)\]\]','$1')
    return ([regex]::Replace($text,'\s+',' ')).Trim()
}

function Get-FsExtValue {
    param($ExtMetadata,[string]$Name)
    if ($null -eq $ExtMetadata) { return $null }
    $prop=$ExtMetadata.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
    $valueProp=$prop.Value.PSObject.Properties['value']
    if ($valueProp) { return [string]$valueProp.Value }
    return [string]$prop.Value
}

function Convert-FsImageInfoRecord {
    param($Page)
    $imageInfo=Get-FsPropertyValue -Object $Page -Name 'imageinfo'
    $ii=@($imageInfo | Select-Object -First 1)
    if ($ii.Count -eq 0 -or $null -eq $ii[0]) { return $null }
    $info=$ii[0]
    $ext=Get-FsPropertyValue -Object $info -Name 'extmetadata'
    $lat=$null; $lon=$null
    try {
        $coordinates=Get-FsPropertyValue -Object $Page -Name 'coordinates'
        $coordinate=@($coordinates | Select-Object -First 1)
        if ($coordinate.Count -gt 0 -and $null -ne $coordinate[0]) {
            $latValue=Get-FsPropertyValue -Object $coordinate[0] -Name 'lat'
            $lonValue=Get-FsPropertyValue -Object $coordinate[0] -Name 'lon'
            if ($null -ne $latValue) { $lat=[double]$latValue }
            if ($null -ne $lonValue) { $lon=[double]$lonValue }
        }
    }
    catch {}
    $timestamp=Get-FsPropertyValue -Object $info -Name 'timestamp'
    $title=[string](Get-FsPropertyValue -Object $Page -Name 'title')
    return [pscustomobject]@{
        PageId=[int](Get-FsPropertyValue -Object $Page -Name 'pageid' -Default 0)
        Title=Normalize-FsFileTitle $title
        CanonicalTitle=Normalize-FsFileTitle $title
        Sha1=[string](Get-FsPropertyValue -Object $info -Name 'sha1')
        Url=[string](Get-FsPropertyValue -Object $info -Name 'url')
        DescriptionUrl=[string](Get-FsPropertyValue -Object $info -Name 'descriptionurl')
        Mime=[string](Get-FsPropertyValue -Object $info -Name 'mime')
        MediaType=[string](Get-FsPropertyValue -Object $info -Name 'mediatype')
        Size=[long](Get-FsPropertyValue -Object $info -Name 'size' -Default 0)
        Width=[int](Get-FsPropertyValue -Object $info -Name 'width' -Default 0)
        Height=[int](Get-FsPropertyValue -Object $info -Name 'height' -Default 0)
        CurrentUploader=[string](Get-FsPropertyValue -Object $info -Name 'user')
        CurrentTimestamp=if ($null -ne $timestamp -and -not [string]::IsNullOrWhiteSpace([string]$timestamp)) { ([DateTime]$timestamp).ToUniversalTime().ToString('o') } else { $null }
        Description=ConvertTo-FsPlainText (Get-FsExtValue $ext 'ImageDescription')
        Creator=ConvertTo-FsPlainText (Get-FsExtValue $ext 'Artist')
        License=ConvertTo-FsPlainText (Get-FsExtValue $ext 'LicenseShortName')
        LicenseUrl=[string](Get-FsExtValue $ext 'LicenseUrl')
        Attribution=ConvertTo-FsPlainText (Get-FsExtValue $ext 'Attribution')
        Latitude=$lat
        Longitude=$lon
        MetadataJson=($info | ConvertTo-Json -Depth 40 -Compress)
    }
}

function Convert-FsAllImageRecord {
    param($Image)
    $timestamp=Get-FsPropertyValue -Object $Image -Name 'timestamp'
    return [pscustomobject]@{
        PageId=0
        Title=Normalize-FsFileTitle ([string](Get-FsPropertyValue -Object $Image -Name 'title'))
        Sha1=[string](Get-FsPropertyValue -Object $Image -Name 'sha1')
        Url=[string](Get-FsPropertyValue -Object $Image -Name 'url')
        DescriptionUrl=[string](Get-FsPropertyValue -Object $Image -Name 'descriptionurl')
        Mime=[string](Get-FsPropertyValue -Object $Image -Name 'mime')
        MediaType=[string](Get-FsPropertyValue -Object $Image -Name 'mediatype')
        Size=[long](Get-FsPropertyValue -Object $Image -Name 'size' -Default 0)
        Width=[int](Get-FsPropertyValue -Object $Image -Name 'width' -Default 0)
        Height=[int](Get-FsPropertyValue -Object $Image -Name 'height' -Default 0)
        CurrentUploader=[string](Get-FsPropertyValue -Object $Image -Name 'user')
        CurrentTimestamp=if ($null -ne $timestamp -and -not [string]::IsNullOrWhiteSpace([string]$timestamp)) { ([DateTime]$timestamp).ToUniversalTime().ToString('o') } else { $null }
        MetadataJson=($Image | ConvertTo-Json -Depth 20 -Compress)
    }
}

Export-ModuleMember -Function *-Fs*
