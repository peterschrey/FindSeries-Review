Set-StrictMode -Version 2.0

# HF50: initialize the per-process download claim queue before any StrictMode access.
$script:FsDownloadClaimQueues=@{}
$script:FsDownloadDelayCache=@{}

function Get-FsSha256Text {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-FsPropertyValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p=$Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Normalize-FsMediaIdentityTitle {
    param([string]$Title)
    $normalized = Normalize-FsFileTitle $Title
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    $value = $normalized.Substring(5).Replace('_',' ')
    $value = [regex]::Replace($value,'\s+',' ').Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Normalize-FsMediaIdentitySha1 {
    param([string]$Sha1)
    if ([string]::IsNullOrWhiteSpace($Sha1)) { return $null }
    $value = $Sha1.Trim().ToLowerInvariant()
    if ($value -notmatch '^[0-9a-f]{40}$') { return $null }
    return $value
}

function ConvertTo-FsMediaRecord {
    param($Media)
    if ($Media -is [string]) { return [pscustomobject]@{ Title = [string]$Media } }
    return $Media
}


function Get-FsNotRejectedMediaSqlPredicate {
    param([string]$Alias='m')
    return @"
NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.media_id=$Alias.id)
AND ($Alias.page_id IS NULL OR $Alias.page_id<=0 OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.page_id IS NOT NULL AND r.page_id>0 AND r.page_id=$Alias.page_id))
AND ($Alias.sha1 IS NULL OR $Alias.sha1='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.sha1 IS NOT NULL AND r.sha1<>'' AND r.sha1=$Alias.sha1 COLLATE NOCASE))
AND ($Alias.normalized_title IS NULL OR $Alias.normalized_title='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.normalized_title IS NOT NULL AND r.normalized_title<>'' AND r.normalized_title=$Alias.normalized_title COLLATE NOCASE))
"@
}

function Get-FsMediaIdentityCandidateExpressions {
    param($Media)
    $record = ConvertTo-FsMediaRecord $Media
    $result = @{}
    $sha1 = Normalize-FsMediaIdentitySha1 ([string](Get-FsPropertyValue $record 'Sha1'))
    $pageId = [long](Get-FsPropertyValue $record 'PageId' 0)
    $title = Normalize-FsFileTitle ([string](Get-FsPropertyValue $record 'Title'))
    $titleKey = Normalize-FsMediaIdentityTitle $title
    if($sha1){$v=ConvertTo-FsSqlLiteral $sha1;$result.sha1="COALESCE((SELECT media_id FROM media_identities WHERE identity_type='sha1' AND identity_value=$v LIMIT 1),(SELECT id FROM media WHERE sha1=$v COLLATE NOCASE LIMIT 1),NULL)"}
    if($pageId -gt 0){$v=ConvertTo-FsSqlLiteral ([string]$pageId);$result.pageid="COALESCE((SELECT media_id FROM media_identities WHERE identity_type='pageid' AND identity_value=$v LIMIT 1),(SELECT id FROM media WHERE page_id=$pageId LIMIT 1),NULL)"}
    if($titleKey){$result.title="COALESCE((SELECT media_id FROM media_identities WHERE identity_type='title' AND identity_value=$(ConvertTo-FsSqlLiteral $titleKey) LIMIT 1),(SELECT id FROM media WHERE normalized_title=$(ConvertTo-FsSqlLiteral $titleKey) COLLATE NOCASE OR title=$(ConvertTo-FsSqlLiteral $title) COLLATE NOCASE LIMIT 1),NULL)"}
    return $result
}

function Get-FsMediaLookupSqlExpression {
    param($Media)
    $candidates=Get-FsMediaIdentityCandidateExpressions $Media
    $lookups=New-Object System.Collections.Generic.List[string]
    foreach($name in @('sha1','pageid','title')){if($candidates.ContainsKey($name)){$lookups.Add([string]$candidates[$name])}}
    if($lookups.Count -eq 0){return 'NULL'}
    return 'COALESCE(' + ($lookups -join ',') + ',NULL)'
}

function Get-FsMediaInsertSql {
    param($Record,[string]$Now)
    $record = ConvertTo-FsMediaRecord $Record
    $title = Normalize-FsFileTitle ([string](Get-FsPropertyValue $record 'Title'))
    if ([string]::IsNullOrWhiteSpace($title)) { return $null }
    $canonicalTitle = Normalize-FsFileTitle ([string](Get-FsPropertyValue $record 'CanonicalTitle' $title))
    if ([string]::IsNullOrWhiteSpace($canonicalTitle)) { $canonicalTitle = $title }
    $pageId = [long](Get-FsPropertyValue $record 'PageId' 0)
    $sha1 = Normalize-FsMediaIdentitySha1 ([string](Get-FsPropertyValue $record 'Sha1'))
    $titleKey = Normalize-FsMediaIdentityTitle $title
    $metadataLevel = [int](Get-FsPropertyValue $record 'MetadataLevel' 0)
    $metadataCheckedLevel = [int](Get-FsPropertyValue $record 'MetadataCheckedLevel' 0)

    # Resolve identity candidates only once. The prior implementation rebuilt
    # the same expressions three times per record.
    $candidates = Get-FsMediaIdentityCandidateExpressions $record
    $lookups = New-Object Collections.Generic.List[string]
    foreach($name in @('sha1','pageid','title')){
        if($candidates.ContainsKey($name)){$lookups.Add([string]$candidates[$name])}
    }
    $lookup = if($lookups.Count -gt 0){'COALESCE(' + ($lookups -join ',') + ',NULL)'}else{'NULL'}
    $lookupBefore = $lookup
    $lookupAfter = $lookup

    # Convert every field to its SQL literal once. This is especially important
    # for metadata_json, which can be large and previously was hex-encoded three times.
    $literal = @{
        Now               = ConvertTo-FsSqlLiteral $Now
        Title             = ConvertTo-FsSqlLiteral $title
        TitleKey          = ConvertTo-FsSqlLiteral $titleKey
        CanonicalTitle    = ConvertTo-FsSqlLiteral $canonicalTitle
        Sha1              = ConvertTo-FsSqlLiteral $sha1
        Url               = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Url')
        DescriptionUrl    = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'DescriptionUrl')
        Mime              = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Mime')
        MediaType         = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'MediaType')
        Size              = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Size')
        Width             = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Width')
        Height            = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Height')
        CurrentUploader   = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'CurrentUploader')
        CurrentTimestamp  = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'CurrentTimestamp')
        OriginalUploader  = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'OriginalUploader')
        OriginalTimestamp = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'OriginalTimestamp')
        Description       = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Description')
        Creator           = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Creator')
        License           = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'License')
        LicenseUrl        = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'LicenseUrl')
        Attribution       = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Attribution')
        Latitude          = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Latitude')
        Longitude         = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'Longitude')
        MetadataJson      = ConvertTo-FsSqlLiteral (Get-FsPropertyValue $record 'MetadataJson')
    }
    $pageIdSql = if($pageId -gt 0){[string]$pageId}else{'NULL'}

    $conflictSql = New-Object Collections.Generic.List[string]
    foreach($candidateName in @('sha1','pageid','title')){
        if(-not $candidates.ContainsKey($candidateName)){continue}
        $candidateExpression=[string]$candidates[$candidateName]
        $conflictSql.Add("INSERT OR IGNORE INTO media_identity_conflicts(media_id_a,media_id_b,reason,created_at) SELECT MIN($lookupAfter,$candidateExpression),MAX($lookupAfter,$candidateExpression),$(ConvertTo-FsSqlLiteral ('record-'+$candidateName)),$($literal.Now) WHERE $lookupAfter IS NOT NULL AND $candidateExpression IS NOT NULL AND $lookupAfter<>$candidateExpression;")
    }

    $identitySql = New-Object Collections.Generic.List[string]
    if ($sha1) {
        $identitySql.Add("INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at) SELECT 'sha1',$($literal.Sha1),id,'record',$($literal.Now),$($literal.Now) FROM media WHERE id=$lookupAfter;")
    }
    if ($pageId -gt 0) {
        $pageIdLiteral=ConvertTo-FsSqlLiteral ([string]$pageId)
        $identitySql.Add("INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at) SELECT 'pageid',$pageIdLiteral,id,'record',$($literal.Now),$($literal.Now) FROM media WHERE id=$lookupAfter;")
    }
    if ($titleKey) {
        $identitySql.Add("INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at) SELECT 'title',$($literal.TitleKey),id,'record',$($literal.Now),$($literal.Now) FROM media WHERE id=$lookupAfter;")
    }

    return @"
INSERT OR IGNORE INTO media(page_id,title,normalized_title,canonical_title,sha1,url,description_url,mime,media_type,size,width,height,current_uploader,current_timestamp,original_uploader,original_timestamp,description,creator,license,license_url,attribution,latitude,longitude,metadata_json,metadata_level,metadata_checked_level,created_at,updated_at)
SELECT $pageIdSql,$($literal.Title),$($literal.TitleKey),$($literal.CanonicalTitle),$($literal.Sha1),$($literal.Url),$($literal.DescriptionUrl),$($literal.Mime),$($literal.MediaType),$($literal.Size),$($literal.Width),$($literal.Height),$($literal.CurrentUploader),$($literal.CurrentTimestamp),$($literal.OriginalUploader),$($literal.OriginalTimestamp),$($literal.Description),$($literal.Creator),$($literal.License),$($literal.LicenseUrl),$($literal.Attribution),$($literal.Latitude),$($literal.Longitude),$($literal.MetadataJson),$metadataLevel,$metadataCheckedLevel,$($literal.Now),$($literal.Now)
WHERE $lookupBefore IS NULL;

UPDATE media SET
 normalized_title=COALESCE(normalized_title,$($literal.TitleKey)),
 page_id=CASE WHEN $pageId>0 AND NOT EXISTS(SELECT 1 FROM media x WHERE x.page_id=$pageId AND x.id<>$lookupAfter) THEN $pageId ELSE page_id END,
 canonical_title=COALESCE(NULLIF($($literal.CanonicalTitle),''),canonical_title),
 sha1=CASE WHEN $($literal.Sha1) IS NOT NULL AND NOT EXISTS(SELECT 1 FROM media x WHERE x.sha1=$($literal.Sha1) COLLATE NOCASE AND x.id<>$lookupAfter) THEN $($literal.Sha1) ELSE sha1 END,
 url=COALESCE(NULLIF($($literal.Url),''),url),
 description_url=COALESCE(NULLIF($($literal.DescriptionUrl),''),description_url),
 mime=COALESCE(NULLIF($($literal.Mime),''),mime),
 media_type=COALESCE(NULLIF($($literal.MediaType),''),media_type),
 size=COALESCE($($literal.Size),size),
 width=COALESCE($($literal.Width),width),
 height=COALESCE($($literal.Height),height),
 current_uploader=COALESCE(NULLIF($($literal.CurrentUploader),''),current_uploader),
 current_timestamp=COALESCE(NULLIF($($literal.CurrentTimestamp),''),current_timestamp),
 original_uploader=COALESCE(NULLIF($($literal.OriginalUploader),''),original_uploader),
 original_timestamp=COALESCE(NULLIF($($literal.OriginalTimestamp),''),original_timestamp),
 description=COALESCE(NULLIF($($literal.Description),''),description),
 creator=COALESCE(NULLIF($($literal.Creator),''),creator),
 license=COALESCE(NULLIF($($literal.License),''),license),
 license_url=COALESCE(NULLIF($($literal.LicenseUrl),''),license_url),
 attribution=COALESCE(NULLIF($($literal.Attribution),''),attribution),
 latitude=COALESCE($($literal.Latitude),latitude),
 longitude=COALESCE($($literal.Longitude),longitude),
 metadata_json=CASE WHEN $metadataLevel>=metadata_level AND $($literal.MetadataJson) IS NOT NULL THEN $($literal.MetadataJson) ELSE metadata_json END,
 metadata_level=MAX(metadata_level,$metadataLevel),
 metadata_checked_level=MAX(metadata_checked_level,$metadataCheckedLevel),
 updated_at=$($literal.Now)
WHERE id=$lookupAfter;
$($conflictSql -join "`n")
$($identitySql -join "`n")
"@
}

function Get-FsProjectMediaSql {
    param([int]$ProjectId,$Media,[int]$Score,[string]$Source,[string]$Now)
    $lookup = Get-FsMediaLookupSqlExpression $Media
    $notRejected=Get-FsNotRejectedMediaSqlPredicate -Alias 'm'
    return @"
INSERT INTO project_media(project_id,media_id,score,best_source,selected,first_seen_at,updated_at)
SELECT $ProjectId,m.id,$Score,$(ConvertTo-FsSqlLiteral $Source),1,$(ConvertTo-FsSqlLiteral $Now),$(ConvertTo-FsSqlLiteral $Now)
FROM media m
WHERE m.id=$lookup AND $notRejected
ON CONFLICT(project_id,media_id) DO UPDATE SET score=MAX(project_media.score,excluded.score), best_source=CASE WHEN excluded.score>=project_media.score THEN excluded.best_source ELSE project_media.best_source END, updated_at=excluded.updated_at;
"@
}

function Get-FsDiscoverySql {
    param([int]$ProjectId,$Media,[string]$SourceType,[string]$SourceValue,[int]$Score,[string]$Language,[string]$QueryText,[Nullable[int]]$OriginCategoryId,[Nullable[int]]$ParentMediaId,$Details,[string]$Now)
    $detailsJson=if($null -ne $Details){$Details|ConvertTo-Json -Depth 15 -Compress}else{$null}
    $lookup = Get-FsMediaLookupSqlExpression $Media
    $notRejected=Get-FsNotRejectedMediaSqlPredicate -Alias 'm'
    return @"
INSERT OR IGNORE INTO discoveries(project_id,media_id,source_type,source_value,score,language,query_text,origin_category_id,parent_media_id,details_json,created_at)
SELECT $ProjectId,m.id,$(ConvertTo-FsSqlLiteral $SourceType),$(ConvertTo-FsSqlLiteral $SourceValue),$Score,$(ConvertTo-FsSqlLiteral $Language),$(ConvertTo-FsSqlLiteral $QueryText),$(ConvertTo-FsSqlLiteral $OriginCategoryId),$(ConvertTo-FsSqlLiteral $ParentMediaId),$(ConvertTo-FsSqlLiteral $detailsJson),$(ConvertTo-FsSqlLiteral $Now)
FROM media m WHERE m.id=$lookup AND $notRejected;
"@
}


function Format-FsSearchDuration {
    param([double]$Seconds)
    if($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)){return '--:--'}
    $span=[TimeSpan]::FromSeconds($Seconds)
    if($span.TotalDays -ge 1){return $span.ToString('d\.hh\:mm\:ss')}
    if($span.TotalHours -ge 1){return $span.ToString('hh\:mm\:ss')}
    return $span.ToString('mm\:ss')
}

function Get-FsTermMatchKey {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $key=$Value.Trim().ToLowerInvariant().Replace('_',' ')
    $key=[regex]::Replace($key,'[^\p{L}\p{Nd}]+',' ')
    $key=[regex]::Replace($key,'\s+',' ').Trim()
    return $key
}

function Test-FsExactTermMatch {
    param([string]$Candidate,[string]$Expected)
    $candidateKey=Get-FsTermMatchKey $Candidate
    $expectedKey=Get-FsTermMatchKey $Expected
    return (-not[string]::IsNullOrWhiteSpace($candidateKey) -and $candidateKey -eq $expectedKey)
}

function Ensure-FsTranslationConcept {
    param(
        [string]$Seed,[string]$InputLanguage,[string]$Domain,[string]$SqlitePath,[string]$DatabasePath,
        [hashtable]$ApiConfig,[hashtable]$Headers,[Nullable[int]]$ProjectId,[Nullable[int]]$RunId,
        [switch]$ShowProgress,[int]$ConceptIndex=0,[int]$ConceptCount=0
    )

    $term=$Seed.Trim()
    $qid=$null
    $explicitQid=$false
    $resolution=$null
    $conceptPrefix=if($ConceptCount -gt 0){"Konzept $ConceptIndex/$ConceptCount"}else{'Konzept'}

    if($ShowProgress){Write-Host ("        [TERM] ${conceptPrefix}: '$term' prüfen ...") -ForegroundColor DarkGray}

    if($term -match '^(?<term>.*?)::(?<qid>Q\d+)$'){
        $term=$matches.term.Trim()
        $qid=$matches.qid
        $explicitQid=$true
        $resolution='explicit-qid'
        if($ShowProgress){Write-Host ("        [TERM] ${conceptPrefix}: explizite QID $qid") -ForegroundColor DarkGray}
    }

    if(-not $qid){
        $cacheRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT tc.concept_id,t.term,t.term_type,t.priority
FROM translation_concepts tc
LEFT JOIN translations t
  ON t.concept_id=tc.concept_id
 AND t.language=$(ConvertTo-FsSqlLiteral $InputLanguage)
WHERE tc.seed_key=$(ConvertTo-FsSqlLiteral $term.ToLowerInvariant())
ORDER BY t.priority DESC,t.term;
"@)

        $acceptedCache=@(
            $cacheRows |
                Where-Object {
                    -not[string]::IsNullOrWhiteSpace([string]$_.concept_id) -and
                    (Test-FsExactTermMatch -Candidate ([string]$_.term) -Expected $term)
                } |
                Select-Object -First 1
        )

        if($acceptedCache.Count -gt 0){
            $qid=[string]$acceptedCache[0].concept_id
            $resolution='validated-cache'
            if($ShowProgress){Write-Host ("        [TERM] ${conceptPrefix}: validierte Cache-QID $qid") -ForegroundColor DarkGray}
        }
        elseif($cacheRows.Count -gt 0){
            $cachedIds=(@($cacheRows.concept_id)|Where-Object{$_}|Select-Object -Unique) -join ', '
            $message="Unsichere Cache-Zuordnung für '$term' verworfen: $cachedIds enthält kein exakt passendes '$InputLanguage'-Label/Alias."
            Write-Warning $message
            try{
                Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -Stage 'translations' -Level 'warning' -Message $message -Details @{term=$term;language=$InputLanguage;cached_qids=$cachedIds}
            }catch{}
        }
    }

    if(-not $qid){
        if($ShowProgress){Write-Host ("        [TERM] ${conceptPrefix}: Wikidata nach exaktem Label/Alias durchsuchen ...") -ForegroundColor DarkGray}

        $response=Invoke-FsWikidataApi -Parameters @{
            action='wbsearchentities'
            search=$term
            language=$InputLanguage
            uselang=$InputLanguage
            type='item'
            limit=10
        } -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs ([int]$ApiConfig.DelayMs) -Retries ([int]$ApiConfig.Retries) -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage 'translations'

        $searchResults=@()
        if($null -ne $response -and $null -ne $response.PSObject.Properties['search']){
            $searchResults=@($response.search)
        }

        $exactHits=New-Object Collections.Generic.List[object]
        foreach($candidate in $searchResults){
            if($null -eq $candidate){continue}
            $candidateId=[string](Get-FsPropertyValue $candidate 'id')
            if($candidateId -notmatch '^Q\d+$'){continue}

            $candidateTexts=New-Object Collections.Generic.List[string]
            $label=[string](Get-FsPropertyValue $candidate 'label')
            if(-not[string]::IsNullOrWhiteSpace($label)){$candidateTexts.Add($label)}

            $matchObject=Get-FsPropertyValue $candidate 'match'
            $matchText=[string](Get-FsPropertyValue $matchObject 'text')
            if(-not[string]::IsNullOrWhiteSpace($matchText)){$candidateTexts.Add($matchText)}

            foreach($alias in @((Get-FsPropertyValue $candidate 'aliases' @()))){
                $aliasText=if($alias -is [string]){[string]$alias}else{[string](Get-FsPropertyValue $alias 'value')}
                if(-not[string]::IsNullOrWhiteSpace($aliasText)){$candidateTexts.Add($aliasText)}
            }

            if(@($candidateTexts|Where-Object{Test-FsExactTermMatch -Candidate $_ -Expected $term}).Count -gt 0){
                $exactHits.Add($candidate)
            }
        }

        if($exactHits.Count -gt 0){
            $qid=[string](Get-FsPropertyValue $exactHits[0] 'id')
            $resolution='exact-wikidata-search'
            if($ShowProgress){Write-Host ("        [TERM] ${conceptPrefix}: exakt passende Wikidata-QID $qid gewählt") -ForegroundColor DarkGray}
        }
    }

    if(-not $qid){
        $message="Kein eindeutig passendes Wikidata-Konzept für '$term'. Der Begriff wird wörtlich in Sprache '$InputLanguage' gesucht; automatische Übersetzungen und Wikidata-Synonyme entfallen."
        Write-Warning $message
        if($ShowProgress){
            Write-Host ("        [TERM] ${conceptPrefix}: Literal-Fallback '$term' ($InputLanguage)") -ForegroundColor DarkYellow
        }
        try{
            Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -Stage 'translations' -Level 'warning' -Message $message -Details @{term=$term;language=$InputLanguage;fallback='literal'}
        }catch{}
        return [pscustomobject]@{
            Term=$term
            Qid=$null
            IsLiteral=$true
            Resolution='literal-fallback'
        }
    }

    $now=Get-FsUtcNowText
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
INSERT INTO translation_concepts(concept_id,seed_term,seed_key,domain,resolved_at)
VALUES($(ConvertTo-FsSqlLiteral $qid),$(ConvertTo-FsSqlLiteral $term),$(ConvertTo-FsSqlLiteral $term.ToLowerInvariant()),$(ConvertTo-FsSqlLiteral $Domain),$(ConvertTo-FsSqlLiteral $now))
ON CONFLICT(concept_id) DO UPDATE SET
 seed_term=COALESCE(translation_concepts.seed_term,excluded.seed_term),
 seed_key=COALESCE(translation_concepts.seed_key,excluded.seed_key),
 domain=COALESCE(translation_concepts.domain,excluded.domain),
 resolved_at=excluded.resolved_at;
"@ | Out-Null

    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
INSERT OR IGNORE INTO translations(concept_id,language,term,term_key,term_type,priority,created_at)
VALUES($(ConvertTo-FsSqlLiteral $qid),$(ConvertTo-FsSqlLiteral $InputLanguage),$(ConvertTo-FsSqlLiteral $term),$(ConvertTo-FsSqlLiteral $term.ToLowerInvariant()),'explicit',110,$(ConvertTo-FsSqlLiteral $now));
"@ | Out-Null

    $countRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql ("SELECT COUNT(*) count FROM translations WHERE concept_id="+(ConvertTo-FsSqlLiteral $qid)+";"))
    $inputRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql ("SELECT term FROM translations WHERE concept_id="+(ConvertTo-FsSqlLiteral $qid)+" AND language="+(ConvertTo-FsSqlLiteral $InputLanguage)+";"))
    $hasExactInput=@($inputRows|Where-Object{Test-FsExactTermMatch -Candidate ([string]$_.term) -Expected $term}).Count -gt 0

    if([int]$countRows[0].count -le 1 -or -not $hasExactInput -or $explicitQid){
        if($ShowProgress){Write-Host ("        [TERM] ${conceptPrefix}: Labels und Synonyme von Wikidata laden/aktualisieren ...") -ForegroundColor DarkGray}

        $entityResponse=Invoke-FsWikidataApi -Parameters @{
            action='wbgetentities'
            ids=$qid
            props='labels|aliases'
        } -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs ([int]$ApiConfig.DelayMs) -Retries ([int]$ApiConfig.Retries) -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage 'translations'

        $entity=$null
        if($null -ne $entityResponse -and $null -ne $entityResponse.PSObject.Properties['entities']){
            $entityProperty=$entityResponse.entities.PSObject.Properties[$qid]
            if($null -ne $entityProperty){$entity=$entityProperty.Value}
        }

        $statements=New-Object Collections.Generic.List[string]
        $labels=Get-FsPropertyValue $entity 'labels'
        if($null -ne $labels){
            foreach($p in @($labels.PSObject.Properties)){
                $lang=[string]$p.Name
                $value=[string](Get-FsPropertyValue $p.Value 'value')
                if([string]::IsNullOrWhiteSpace($value)){continue}
                $priority=if($lang -eq $InputLanguage){100}elseif($lang -eq 'en'){90}else{70}
                $statements.Add("INSERT OR IGNORE INTO translations(concept_id,language,term,term_key,term_type,priority,created_at) VALUES($(ConvertTo-FsSqlLiteral $qid),$(ConvertTo-FsSqlLiteral $lang),$(ConvertTo-FsSqlLiteral $value),$(ConvertTo-FsSqlLiteral $value.ToLowerInvariant()),'label',$priority,$(ConvertTo-FsSqlLiteral $now));")
            }
        }

        $aliases=Get-FsPropertyValue $entity 'aliases'
        if($null -ne $aliases){
            foreach($p in @($aliases.PSObject.Properties)){
                $lang=[string]$p.Name
                $priority=if($lang -eq $InputLanguage){90}elseif($lang -eq 'en'){80}else{60}
                foreach($alias in @($p.Value)){
                    $value=[string](Get-FsPropertyValue $alias 'value')
                    if([string]::IsNullOrWhiteSpace($value)){continue}
                    $statements.Add("INSERT OR IGNORE INTO translations(concept_id,language,term,term_key,term_type,priority,created_at) VALUES($(ConvertTo-FsSqlLiteral $qid),$(ConvertTo-FsSqlLiteral $lang),$(ConvertTo-FsSqlLiteral $value),$(ConvertTo-FsSqlLiteral $value.ToLowerInvariant()),'alias',$priority,$(ConvertTo-FsSqlLiteral $now));")
                }
            }
        }

        if($statements.Count -gt 0){
            Invoke-FsSqlBatch -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Statements $statements.ToArray() -Immediate
        }
        if($ShowProgress){Write-Host ("        [TERM] ${conceptPrefix}: $($statements.Count) Wikidata-Übersetzung(en) ergänzt") -ForegroundColor DarkGray}
    }
    elseif($ShowProgress){
        Write-Host ("        [TERM] ${conceptPrefix}: $([int]$countRows[0].count) validierte Übersetzung(en) vorhanden") -ForegroundColor DarkGray
    }

    return [pscustomobject]@{
        Term=$term
        Qid=$qid
        IsLiteral=$false
        Resolution=$resolution
    }
}

function Get-FsCartesianProduct {
    param([object[]]$Lists,[int]$Limit)
    $result=New-Object Collections.Generic.List[object]
    function Add-Level([int]$index,[object[]]$current) {
        if($result.Count -ge $Limit){return}
        if($index -ge $Lists.Count){$result.Add(@($current));return}
        foreach($item in @($Lists[$index])) { Add-Level ($index+1) (@($current)+@($item)); if($result.Count -ge $Limit){break} }
    }
    Add-Level 0 @()
    return $result.ToArray()
}

function New-FsKeywordQueries {
    param(
        [string[]]$Groups,[string]$InputLanguage,[string]$Domain,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath,[hashtable]$Headers,[Nullable[int]]$ProjectId,[Nullable[int]]$RunId,
        [switch]$ShowProgress
    )
    $queries=New-Object Collections.Generic.List[object]
    $groupList=@($Groups|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    $allParts=@($groupList|ForEach-Object{$_ -split '\+'}|ForEach-Object{$_.Trim()}|Where-Object{$_}|Select-Object -Unique)
    $conceptMap=@{}
    $conceptIndex=0
    $globalWatch=[Diagnostics.Stopwatch]::StartNew()
    $completedGroupSeconds=0.0

    for($groupOffset=0;$groupOffset -lt $groupList.Count;$groupOffset++) {
        $group=$groupList[$groupOffset]
        $groupIndex=$groupOffset+1
        $groupWatch=[Diagnostics.Stopwatch]::StartNew()
        $parts=@($group -split '\+' | ForEach-Object {$_.Trim()} | Where-Object {$_})
        if($parts.Count -eq 0){continue}
        if($ShowProgress){Write-Host ("        [QUERY] Gruppe $groupIndex/$($groupList.Count): '$group'") -ForegroundColor Gray}

        $concepts=New-Object Collections.Generic.List[object]
        foreach($part in $parts){
            $conceptKey=$part.ToLowerInvariant()
            if($conceptMap.ContainsKey($conceptKey)){$concept=$conceptMap[$conceptKey]}
            else{
                $conceptIndex++
                $concept=Ensure-FsTranslationConcept -Seed $part -InputLanguage $InputLanguage -Domain $Domain -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ApiConfig $Config.Api -Headers $Headers -ProjectId $ProjectId -RunId $RunId -ShowProgress:$ShowProgress -ConceptIndex $conceptIndex -ConceptCount $allParts.Count
                $conceptMap[$conceptKey]=$concept
            }
            $concepts.Add($concept)
        }

        $resolvedConcepts=@($concepts|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_.Qid)})
        $literalConcepts=@($concepts|Where-Object{[bool]$_.IsLiteral -or [string]::IsNullOrWhiteSpace([string]$_.Qid)})

        if($literalConcepts.Count -gt 0){
            # Literal-Fallbacks besitzen bewusst nur die Eingabesprache. Es werden keine
            # Übersetzungen erfunden und keine unsicheren Wikidata-Zuordnungen erzwungen.
            $languages=@($InputLanguage)
            if($ShowProgress){
                $literalNames=($literalConcepts|ForEach-Object{$_.Term}) -join ', '
                Write-Host ("        [QUERY] Literal-Fallback aktiv für: $literalNames; Suche nur in '$InputLanguage'.") -ForegroundColor DarkYellow
            }
        }else{
            $qidList=@($resolvedConcepts|ForEach-Object{$_.Qid})
            $in=($qidList|ForEach-Object{ConvertTo-FsSqlLiteral $_}) -join ','
            $languageRows=Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT language,COUNT(DISTINCT concept_id) concepts FROM translations WHERE concept_id IN ($in) GROUP BY language HAVING concepts=$($qidList.Count);"
            $availableLanguages=@($languageRows.language)
            $priorityLang=@($InputLanguage,'en','de')+@($availableLanguages|Sort-Object)
            $languages=@(
                $priorityLang |
                    Where-Object { $_ -eq $InputLanguage -or $availableLanguages -contains $_ } |
                    Select-Object -Unique
            )
            if([int]$Config.Keyword.MaxLanguages -gt 0){$languages=@($languages|Select-Object -First ([int]$Config.Keyword.MaxLanguages))}
        }
        if($ShowProgress){Write-Host ("        [QUERY] $($languages.Count) verwendbare Sprache(n); max. $([int]$Config.Keyword.MaxQueries) Abfragen insgesamt.") -ForegroundColor DarkGray}

        $langIndex=0
        foreach($lang in $languages) {
            $langIndex++
            $termLists=New-Object Collections.Generic.List[object]
            $languageUsable=$true

            foreach($concept in $concepts) {
                if([bool]$concept.IsLiteral -or [string]::IsNullOrWhiteSpace([string]$concept.Qid)){
                    if($lang -ne $InputLanguage){
                        $languageUsable=$false
                        break
                    }
                    $termLists.Add(@([string]$concept.Term))
                    continue
                }

                $rows=Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT term FROM translations WHERE concept_id=$(ConvertTo-FsSqlLiteral $concept.Qid) AND language=$(ConvertTo-FsSqlLiteral $lang) ORDER BY priority DESC,term LIMIT $([int]$Config.Keyword.MaxSynonymsPerConcept);"
                $terms=@($rows.term|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})

                # Der explizit eingegebene Begriff bleibt auch dann aktiv, wenn Wikidata
                # für die Eingabesprache kein Label liefert.
                if($terms.Count -eq 0 -and $lang -eq $InputLanguage){
                    $terms=@([string]$concept.Term)
                }
                if($terms.Count -eq 0){
                    $languageUsable=$false
                    break
                }
                $termLists.Add($terms)
            }

            if(-not $languageUsable -or $termLists.Count -ne $concepts.Count){
                if($ShowProgress){Write-Host ("        [QUERY] Sprache '$lang' übersprungen: nicht alle Gruppenteile verfügbar.") -ForegroundColor DarkYellow}
                continue
            }

            $combinations=Get-FsCartesianProduct -Lists $termLists.ToArray() -Limit ([int]$Config.Keyword.MaxQueriesPerLanguage)
            foreach($combo in $combinations) {
                $escaped=@($combo|ForEach-Object{if(([string]$_) -match '\s'){ '"'+([string]$_).Replace('"','')+'"' }else{[string]$_}})
                $normal=$escaped -join ' '
                $title=(@($escaped|ForEach-Object{'intitle:'+$_}) -join ' ')
                $queries.Add([pscustomobject]@{Text=$normal;Language=$lang;Score=72;Type='keyword-group';Source=$group})
                $queries.Add([pscustomobject]@{Text=$title;Language=$lang;Score=78;Type='keyword-title';Source=$group})
                if($queries.Count -ge [int]$Config.Keyword.MaxQueries){break}
            }

            if($ShowProgress -and ($langIndex -eq 1 -or ($langIndex % 10) -eq 0 -or $langIndex -eq $languages.Count)){
                $rate=$langIndex/[Math]::Max(0.001,$groupWatch.Elapsed.TotalSeconds)
                $remainingCurrent=$languages.Count-$langIndex
                $currentEta=if($rate -gt 0){$remainingCurrent/$rate}else{-1}
                $averageGroup=if($groupIndex -gt 1){$completedGroupSeconds/($groupIndex-1)}else{$groupWatch.Elapsed.TotalSeconds}
                $remainingGroups=$groupList.Count-$groupIndex
                $totalEta=$currentEta+($remainingGroups*$averageGroup)
                $etaText=Format-FsSearchDuration $totalEta
                $finishText=if($totalEta -ge 0){[DateTime]::Now.AddSeconds($totalEta).ToString('dd.MM.yyyy HH:mm:ss')}else{'--'}
                $status=("Gruppe $groupIndex/$($groupList.Count) | Sprache $langIndex/$($languages.Count) ($lang) | $($queries.Count) Queries | Restdauer $etaText | Ende ca. $finishText")
                Write-Progress -Activity 'Suchbegriffe und Übersetzungen vorbereiten' -Status $status -PercentComplete ([Math]::Min(99,(($groupIndex-1+($langIndex/[Math]::Max(1,$languages.Count)))*100.0)/[Math]::Max(1,$groupList.Count)))
                Write-Host ("        [QUERY] $status") -ForegroundColor DarkGray
            }
            if($queries.Count -ge [int]$Config.Keyword.MaxQueries){break}
        }
        $completedGroupSeconds+=$groupWatch.Elapsed.TotalSeconds
        if($queries.Count -ge [int]$Config.Keyword.MaxQueries){break}
    }
    if($ShowProgress){
        Write-Progress -Activity 'Suchbegriffe und Übersetzungen vorbereiten' -Completed
        Write-Host ("        [QUERY] Generierung beendet: $($queries.Count) Abfrage(n) in $(Format-FsSearchDuration $globalWatch.Elapsed.TotalSeconds).") -ForegroundColor DarkGray
    }
    return $queries.ToArray()
}

function Seed-FsCategoryTasks {
    param([int]$ProjectId,[string[]]$Categories,[string]$SqlitePath,[string]$DatabasePath)
    $now=Get-FsUtcNowText; $statements=New-Object Collections.Generic.List[string]
    foreach($raw in @($Categories)) {
        $title=Normalize-FsCategoryTitle $raw; if(-not $title){continue}; $norm=$title.ToLowerInvariant()
        $statements.Add("INSERT OR IGNORE INTO categories(title,normalized_title,created_at) VALUES($(ConvertTo-FsSqlLiteral $title),$(ConvertTo-FsSqlLiteral $norm),$(ConvertTo-FsSqlLiteral $now));")
        $statements.Add("INSERT OR IGNORE INTO project_categories(project_id,category_id,depth,status,discovered_at,updated_at) SELECT $ProjectId,id,0,'pending',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now) FROM categories WHERE normalized_title=$(ConvertTo-FsSqlLiteral $norm);")
    }
    Invoke-FsSqlBatch -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Statements $statements.ToArray() -Immediate
}

function Seed-FsSearchTasks {
    param(
        [int]$ProjectId,[string[]]$Keywords,[string[]]$KeywordGroups,[string[]]$Depicts,[string]$Language,[string]$Domain,
        [hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath,[hashtable]$Headers,[Nullable[int]]$RunId,
        [switch]$ShowProgress
    )
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $queries=New-Object Collections.Generic.List[object]
    if($ShowProgress){Write-Host ("        [SEED] Explizite Keywords: $(@($Keywords).Count); Gruppen: $(@($KeywordGroups).Count); Depicts: $(@($Depicts).Count)") -ForegroundColor DarkGray}
    foreach($term in @($Keywords)) {
        if([string]::IsNullOrWhiteSpace($term)){continue}; $q=if($term -match '\s'){'"'+$term.Replace('"','')+'"'}else{$term}
        $queries.Add([pscustomobject]@{Text=$q;Language=$Language;Score=72;Type='keyword';Source=$term})
        $queries.Add([pscustomobject]@{Text=('intitle:'+$q);Language=$Language;Score=78;Type='keyword-title';Source=$term})
    }
    if(@($KeywordGroups).Count -gt 0) {
        foreach($q in @(New-FsKeywordQueries -Groups $KeywordGroups -InputLanguage $Language -Domain $Domain -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Headers $Headers -ProjectId $ProjectId -RunId $RunId -ShowProgress:$ShowProgress)){ $queries.Add($q) }
    }
    foreach($qid in @($Depicts)) {
        if($qid -notmatch '^Q\d+$'){throw "Ungültige Depicts-QID: $qid"}
        $queries.Add([pscustomobject]@{Text="haswbstatement:P180=$qid";Language='mul';Score=100;Type='depicts';Source=$qid})
    }
    $selected=@($queries|Select-Object -First ([int]$Config.Keyword.MaxQueries))
    if($ShowProgress){Write-Host ("        [SEED] $($selected.Count) SQL-Task(s) in einer Transaktion speichern ...") -ForegroundColor DarkGray}
    $now=Get-FsUtcNowText; $statements=New-Object Collections.Generic.List[string]
    $statements.Add("DROP TABLE IF EXISTS fs_current_search_keys; CREATE TEMP TABLE fs_current_search_keys(query_key TEXT PRIMARY KEY);")
    $index=0
    foreach($q in $selected) {
        $index++
        $key=Get-FsSha256Text ("$($q.Type)|$($q.Language)|$($q.Text)")
        $statements.Add("INSERT OR IGNORE INTO fs_current_search_keys(query_key) VALUES($(ConvertTo-FsSqlLiteral $key));")
        $statements.Add(@"
INSERT INTO search_tasks(project_id,task_type,query_key,query_text,language,score,max_results,status,created_at,updated_at)
VALUES($ProjectId,$(ConvertTo-FsSqlLiteral $q.Type),$(ConvertTo-FsSqlLiteral $key),$(ConvertTo-FsSqlLiteral $q.Text),$(ConvertTo-FsSqlLiteral $q.Language),$([int]$q.Score),$([int]$Config.Keyword.MaxResultsPerQuery),'pending',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now))
ON CONFLICT(project_id,query_key) DO UPDATE SET
 task_type=excluded.task_type,
 query_text=excluded.query_text,
 language=excluded.language,
 score=MAX(search_tasks.score,excluded.score),
 max_results=MAX(search_tasks.max_results,excluded.max_results),
 status=CASE WHEN search_tasks.status IN ('failed','skipped') THEN 'pending' ELSE search_tasks.status END,
 attempts=CASE WHEN search_tasks.status IN ('failed','skipped') THEN 0 ELSE search_tasks.attempts END,
 last_error=CASE WHEN search_tasks.status IN ('failed','skipped') THEN NULL ELSE search_tasks.last_error END,
 lease_owner=CASE WHEN search_tasks.status IN ('failed','skipped') THEN NULL ELSE search_tasks.lease_owner END,
 lease_until=CASE WHEN search_tasks.status IN ('failed','skipped') THEN NULL ELSE search_tasks.lease_until END,
 updated_at=excluded.updated_at;
"@)
        if($ShowProgress -and ($index % 250) -eq 0){Write-Progress -Activity 'Suchaufgaben in SQLite vorbereiten' -Status "$index/$($selected.Count)" -PercentComplete (($index*100.0)/[Math]::Max(1,$selected.Count))}
    }
    $statements.Add(@"
DELETE FROM search_tasks
WHERE project_id=$ProjectId
  AND status IN ('pending','failed','skipped')
  AND query_key NOT IN (SELECT query_key FROM fs_current_search_keys);
DROP TABLE IF EXISTS fs_current_search_keys;
"@)
    Invoke-FsSqlBatch -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Statements $statements.ToArray() -Immediate
    if($ShowProgress){
        Write-Progress -Activity 'Suchaufgaben in SQLite vorbereiten' -Completed
        Write-Host ("        [SEED] abgeschlossen in $(Format-FsSearchDuration $watch.Elapsed.TotalSeconds).") -ForegroundColor DarkGray
    }
    return $selected.Count
}

function Seed-FsMetadataTasks {
    param(
        [int]$ProjectId,
        [int]$Level,
        [string]$SqlitePath,
        [string]$DatabasePath,
        [ValidateRange(100,20000)][int]$SeedBatchSize=2000
    )

    $now=Get-FsUtcNowText
    $notRejected=Get-FsNotRejectedMediaSqlPredicate -Alias 'm'

    # Fast path:
    # 1. Reuse a verified snapshot while project_media is unchanged.
    # 2. Bootstrap the snapshot from complete metadata-task coverage.
    # 3. If coverage is incomplete, inspect only the coverage delta. HF53 no
    #    longer joins every project_media row to media just to discover a few
    #    missing tasks after a merge or interrupted run.
    [object[]]$projectStats=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 15000 -BusyRetries 0 -ProgressLabel 'Metadaten-Projektzustand prüfen' -Sql @"
SELECT COUNT(*) media_count,
       COALESCE(MAX(media_id),0) max_media_id,
       COALESCE(SUM(media_id),0) media_id_sum,
       COALESCE(MAX(updated_at),'') project_updated_at
FROM project_media
WHERE project_id=$ProjectId;
"@)
    $mediaCount=if($projectStats.Count){[int]$projectStats[0].media_count}else{0}
    $maxMediaId=if($projectStats.Count){[long]$projectStats[0].max_media_id}else{0L}
    $mediaIdSum=if($projectStats.Count){[long]$projectStats[0].media_id_sum}else{0L}
    $projectUpdatedAt=if($projectStats.Count){[string]$projectStats[0].project_updated_at}else{''}

    [object[]]$openRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 15000 -BusyRetries 0 -ProgressLabel 'Metadaten-Fast-Path: offene Tasks prüfen' -Sql @"
SELECT EXISTS(
    SELECT 1
    FROM metadata_tasks INDEXED BY ix_metadata_tasks_queue
    WHERE project_id=$ProjectId
      AND status IN ('pending','running','failed')
    LIMIT 1
) open_exists;
"@)
    $openExists=if($openRows.Count){[int]$openRows[0].open_exists}else{1}

    if($mediaCount -le 0){
        return [pscustomobject]@{Level=$Level;Media=0;Scanned=0;AlreadyChecked=0;Open=$openExists;NewlyQueued=0;Candidates=0;Changed=0;SeedBatchSize=$SeedBatchSize;WriteBatchSize=0;SeedSeconds=0;FastPath=$true;FastPathReason='empty'}
    }

    [object[]]$stateRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 5000 -BusyRetries 0 -Sql "SELECT metadata_level,metadata_media_count,metadata_max_media_id,metadata_media_id_sum,COALESCE(metadata_project_updated_at,'') metadata_project_updated_at FROM project_seed_state WHERE project_id=$ProjectId LIMIT 1;")
    $stateValid=$false
    if($openExists -eq 0 -and $stateRows.Count -gt 0){
        $stateValid=([int]$stateRows[0].metadata_level -ge $Level -and
                     [int]$stateRows[0].metadata_media_count -eq $mediaCount -and
                     [long]$stateRows[0].metadata_max_media_id -eq $maxMediaId -and
                     [long]$stateRows[0].metadata_media_id_sum -eq $mediaIdSum -and
                     [string]$stateRows[0].metadata_project_updated_at -eq $projectUpdatedAt)
    }
    if($stateValid){
        Write-Host ("        [META-SEED] Level {0}: verifizierter Projektzustand unverändert; {1} Medien, kein Bestandsscan." -f $Level,$mediaCount) -ForegroundColor DarkGray
        return [pscustomobject]@{Level=$Level;Media=$mediaCount;Scanned=0;AlreadyChecked=$mediaCount;Open=0;NewlyQueued=0;Candidates=0;Changed=0;SeedBatchSize=$SeedBatchSize;WriteBatchSize=0;SeedSeconds=0;FastPath=$true;FastPathReason='snapshot'}
    }

    if($openExists -eq 0){
        [object[]]$coverageRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 15000 -BusyRetries 0 -ProgressLabel 'Metadaten-Fast-Path: Taskabdeckung prüfen' -Sql "SELECT COUNT(*) covered_count,COALESCE(MAX(media_id),0) covered_max_media_id,COALESCE(SUM(media_id),0) covered_media_id_sum FROM metadata_tasks INDEXED BY ix_metadata_tasks_level WHERE project_id=$ProjectId AND required_level>=$Level;")
        $covered=if($coverageRows.Count){[int]$coverageRows[0].covered_count}else{0}
        $coveredMax=if($coverageRows.Count){[long]$coverageRows[0].covered_max_media_id}else{0L}
        $coveredSum=if($coverageRows.Count){[long]$coverageRows[0].covered_media_id_sum}else{0L}
        if($covered -eq $mediaCount -and $coveredMax -eq $maxMediaId -and $coveredSum -eq $mediaIdSum){
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ExecutionTimeoutMs 15000 -Sql @"
INSERT INTO project_seed_state(project_id,metadata_level,metadata_media_count,metadata_max_media_id,metadata_media_id_sum,metadata_project_updated_at,metadata_verified_at,updated_at)
VALUES($ProjectId,$Level,$mediaCount,$maxMediaId,$mediaIdSum,$(ConvertTo-FsSqlLiteral $projectUpdatedAt),$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now))
ON CONFLICT(project_id) DO UPDATE SET
 metadata_level=excluded.metadata_level,
 metadata_media_count=excluded.metadata_media_count,
 metadata_max_media_id=excluded.metadata_max_media_id,
 metadata_media_id_sum=excluded.metadata_media_id_sum,
 metadata_project_updated_at=excluded.metadata_project_updated_at,
 metadata_verified_at=excluded.metadata_verified_at,
 updated_at=excluded.updated_at;
"@ | Out-Null
            Write-Host ("        [META-SEED] Level {0}: Taskabdeckung {1}/{2} bestätigt; Snapshot erstellt, kein Bestandsscan." -f $Level,$covered,$mediaCount) -ForegroundColor DarkGray
            return [pscustomobject]@{Level=$Level;Media=$mediaCount;Scanned=0;AlreadyChecked=$mediaCount;Open=0;NewlyQueued=0;Candidates=0;Changed=0;SeedBatchSize=$SeedBatchSize;WriteBatchSize=0;SeedSeconds=0;FastPath=$true;FastPathReason='coverage'}
        }
    }

    # HF53 exceptional path: inspect only project media that have no metadata
    # task covering the requested level. This is an index-only anti-join over
    # project_media/metadata_tasks, followed by media/rejection checks for the
    # small delta. It avoids the previous cold random lookup of every project
    # medium, which took ~50 s per 2,000 rows on the production workspace.
    $beforeRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 15000 -BusyRetries 0 -Sql "SELECT COUNT(*) count FROM metadata_tasks INDEXED BY ix_metadata_tasks_queue WHERE project_id=$ProjectId AND status IN ('pending','running','failed');")
    $before=if($beforeRows.Count){[int]$beforeRows[0].count}else{0}
    $cursor=0L
    $deltaScanned=0
    $candidateCount=0
    $changed=0
    $batchNo=0
    $effectiveBatchSize=[Math]::Max(100,[Math]::Min(5000,$SeedBatchSize))
    $lastWriteBatchSize=0
    $seedWatch=[Diagnostics.Stopwatch]::StartNew()

    while($true){
        $batchNo++
        $scanSql=@"
WITH fs_metadata_uncovered AS (
    SELECT pm.media_id
    FROM project_media pm INDEXED BY ix_project_media_media_scan
    WHERE pm.project_id=$ProjectId
      AND pm.media_id>$cursor
      AND NOT EXISTS (
          SELECT 1
          FROM metadata_tasks t INDEXED BY ix_metadata_tasks_media_cover
          WHERE t.project_id=$ProjectId
            AND t.media_id=pm.media_id
            AND t.required_level>=$Level
      )
    ORDER BY pm.media_id
    LIMIT $effectiveBatchSize
)
SELECT u.media_id,
       COALESCE(m.metadata_checked_level,0) metadata_checked_level,
       CASE WHEN ($notRejected) THEN 1 ELSE 0 END not_rejected
FROM fs_metadata_uncovered u
JOIN media m ON m.id=u.media_id
ORDER BY u.media_id;
"@
        try{
            [object[]]$scanRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql $scanSql -ExecutionTimeoutMs 120000 -BusyRetries 0 -ProgressLabel ("Metadaten-Abdeckungsdelta lesen | Batch {0}; {1} Delta-Medien geprüft; Cursor {2}" -f $batchNo,$deltaScanned,$cursor))
        }
        catch{
            if($_.Exception.Message -match 'SQLite-Ausführungszeit' -and $effectiveBatchSize -gt 100){
                $effectiveBatchSize=[Math]::Max(100,[int][Math]::Floor($effectiveBatchSize/2.0))
                $batchNo--
                Write-Host ("        [META-SEED] Delta-Lesefenster war zu groß; reduziere auf {0} Medien und setze bei Media-ID {1} fort." -f $effectiveBatchSize,$cursor) -ForegroundColor DarkYellow
                continue
            }
            throw
        }

        if($scanRows.Count -eq 0){break}
        $nextCursor=[long]$scanRows[$scanRows.Count-1].media_id
        if($nextCursor -le $cursor){throw "Metadaten-Seeding konnte den Delta-Cursor nach Media-ID $cursor nicht fortsetzen."}

        [long[]]$uncheckedIds=@(
            $scanRows |
                Where-Object { [int]$_.metadata_checked_level -lt $Level -and [int]$_.not_rejected -eq 1 } |
                ForEach-Object { [long]$_.media_id }
        )

        $eligibleInWindow=$uncheckedIds.Count
        $changedInWindow=0

        if($uncheckedIds.Count -gt 0){
            # Small repair deltas use deliberately small writes. Large first-time
            # seeds keep 500-row writes for throughput. A timeout halves the
            # current chunk and retries the same IDs, down to one row.
            $writeBatchSize=if($uncheckedIds.Count -le 500){100}else{500}
            $writeBatchSize=[Math]::Min($writeBatchSize,$uncheckedIds.Count)
            $offset=0
            while($offset -lt $uncheckedIds.Count){
                $remaining=$uncheckedIds.Count-$offset
                $chunkSize=[Math]::Min($writeBatchSize,$remaining)
                [long[]]$idChunk=@($uncheckedIds | Select-Object -Skip $offset -First $chunkSize)
                if($idChunk.Count -eq 0){break}
                # HF53: the delta query already verified metadata_checked_level and
                # global rejection state. Write the exact IDs directly with a VALUES
                # UPSERT; this avoids a second media/rejection scan and the former temp
                # tables inside the write transaction.
                $nowSql=ConvertTo-FsSqlLiteral $now
                $values=($idChunk | ForEach-Object {
                    "($ProjectId,$([long]$_),$Level,'pending',NULL,NULL,0,NULL,$nowSql)"
                }) -join ','
                $writeSql=@"
BEGIN IMMEDIATE;
INSERT INTO metadata_tasks(
    project_id,media_id,required_level,status,
    lease_owner,lease_until,attempts,last_error,updated_at
)
VALUES $values
ON CONFLICT(project_id,media_id) DO UPDATE SET
    required_level=MAX(metadata_tasks.required_level,excluded.required_level),
    status='pending',
    lease_owner=NULL,
    lease_until=NULL,
    attempts=0,
    last_error=NULL,
    updated_at=excluded.updated_at
WHERE metadata_tasks.required_level<excluded.required_level;
SELECT changes() changed_rows;
COMMIT;
"@
                try{
                    [object[]]$writeRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql $writeSql -ExecutionTimeoutMs 60000 -BusyRetries 0 -ProgressLabel ("Metadaten-Aufgaben schreiben | Delta-Batch {0}; {1} Medien; Chunk {2}" -f $batchNo,$uncheckedIds.Count,$idChunk.Count))
                    if($writeRows.Count -eq 0){throw 'Metadaten-Seeding lieferte keine Schreibstatistik.'}
                    $changedInWindow+=[int]$writeRows[0].changed_rows
                    $offset+=$idChunk.Count
                    $lastWriteBatchSize=$idChunk.Count
                }
                catch{
                    if($_.Exception.Message -match 'SQLite-Ausführungszeit' -and $idChunk.Count -gt 1){
                        $writeBatchSize=[Math]::Max(1,[int][Math]::Floor($idChunk.Count/2.0))
                        Write-Host ("        [META-SEED] Schreibchunk mit {0} Medien überschritt 60 s; reduziere auf {1} und wiederhole denselben Bereich." -f $idChunk.Count,$writeBatchSize) -ForegroundColor DarkYellow
                        continue
                    }
                    throw
                }
            }
        }

        $cursor=$nextCursor
        $deltaScanned+=$scanRows.Count
        $candidateCount+=$eligibleInWindow
        $changed+=$changedInWindow
        Write-Host ("        [META-SEED] Abdeckungsdelta: {0} Medien geprüft; Cursor {1}/{2}; {3} neue Metadatenkandidaten; {4} Tasks neu/aktualisiert; Laufzeit {5}." -f $deltaScanned,$cursor,$maxMediaId,$candidateCount,$changed,(Format-FsSearchDuration $seedWatch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
    }

    [object[]]$afterRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 15000 -BusyRetries 0 -Sql "SELECT COUNT(*) count FROM metadata_tasks INDEXED BY ix_metadata_tasks_queue WHERE project_id=$ProjectId AND status IN ('pending','running','failed');")
    $after=if($afterRows.Count){[int]$afterRows[0].count}else{$changed}

    # If no work remains, the current project inventory has been proven final.
    # A checked medium is authoritative even when no historical task row exists.
    if($after -eq 0){
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ExecutionTimeoutMs 15000 -Sql @"
INSERT INTO project_seed_state(project_id,metadata_level,metadata_media_count,metadata_max_media_id,metadata_media_id_sum,metadata_project_updated_at,metadata_verified_at,updated_at)
VALUES($ProjectId,$Level,$mediaCount,$maxMediaId,$mediaIdSum,$(ConvertTo-FsSqlLiteral $projectUpdatedAt),$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now))
ON CONFLICT(project_id) DO UPDATE SET metadata_level=excluded.metadata_level,metadata_media_count=excluded.metadata_media_count,metadata_max_media_id=excluded.metadata_max_media_id,metadata_media_id_sum=excluded.metadata_media_id_sum,metadata_project_updated_at=excluded.metadata_project_updated_at,metadata_verified_at=excluded.metadata_verified_at,updated_at=excluded.updated_at;
"@ | Out-Null
    }

    return [pscustomobject]@{
        Level=$Level
        Media=$mediaCount
        Scanned=$deltaScanned
        AlreadyChecked=[Math]::Max(0,$mediaCount-$candidateCount)
        Open=$after
        NewlyQueued=[Math]::Max(0,$after-$before)
        Candidates=$candidateCount
        Changed=$changed
        SeedBatchSize=$effectiveBatchSize
        WriteBatchSize=$lastWriteBatchSize
        SeedSeconds=[Math]::Round($seedWatch.Elapsed.TotalSeconds,2)
        FastPath=$false
        FastPathReason='coverage-delta'
    }
}

function Seed-FsNeighborTasks {
    param([int]$ProjectId,[hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath)

    $now=Get-FsUtcNowText
    $max=[Math]::Max(0,[int]$Config.Neighbors.MaxSeeds)
    $min=[int]$Config.Neighbors.MinScore
    if($max -le 0){return [pscustomobject]@{Maximum=0;Existing=0;Inserted=0;Scanned=0;SeedSeconds=0}}

    $existingRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT COUNT(*) count FROM neighbor_tasks WHERE project_id=$ProjectId AND status<>'skipped';")
    $existing=if($existingRows.Count){[int]$existingRows[0].count}else{0}
    if($existing -ge $max){
        Write-Host ("        [NEIGHBOR-SEED] bereits {0}/{1} Seed-Aufgaben vorhanden; kein Seeding erforderlich." -f $existing,$max) -ForegroundColor DarkGray
        return [pscustomobject]@{Maximum=$max;Existing=$existing;Inserted=0;Scanned=0;SeedSeconds=0}
    }

    $batchSize=if($Config.Neighbors.ContainsKey('SeedBatchSize')){[Math]::Max(100,[int]$Config.Neighbors.SeedBatchSize)}else{500}
    $effectiveBatchSize=$batchSize
    $cursorScore=2147483647
    $cursorMediaId=0L
    $scanned=0
    $inserted=0
    $batchNo=0
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $notRejected=Get-FsNotRejectedMediaSqlPredicate -Alias 'm'

    while(($existing+$inserted) -lt $max){
        $remaining=$max-($existing+$inserted)
        $batchNo++
        $sql=@"
BEGIN IMMEDIATE;
CREATE TEMP TABLE fs_neighbor_seed_scan(
 media_id INTEGER PRIMARY KEY,
 score INTEGER NOT NULL
);
INSERT INTO fs_neighbor_seed_scan(media_id,score)
SELECT pm.media_id,pm.score
FROM project_media pm INDEXED BY ix_project_media_score
WHERE pm.project_id=$ProjectId
  AND pm.selected=1
  AND pm.score>=$min
  AND (pm.score<$cursorScore OR (pm.score=$cursorScore AND pm.media_id>$cursorMediaId))
ORDER BY pm.score DESC,pm.media_id ASC
LIMIT $effectiveBatchSize;

-- HF53: CROSS JOIN fixes the join order. With a tiny TEMP seed batch SQLite
-- must scan fs_neighbor_seed_scan first and then resolve media by rowid. A normal
-- INNER JOIN can be reordered into a full scan of the entire media table.
INSERT OR IGNORE INTO neighbor_tasks(project_id,media_id,status,updated_at)
SELECT $ProjectId,s.media_id,'pending',$(ConvertTo-FsSqlLiteral $now)
FROM fs_neighbor_seed_scan s
CROSS JOIN media m
WHERE m.id=s.media_id
  AND m.metadata_level>=1
  AND m.current_uploader IS NOT NULL
  AND m.current_uploader<>''
  AND ($notRejected)
  AND NOT EXISTS(
      SELECT 1 FROM neighbor_tasks nt
      WHERE nt.project_id=$ProjectId AND nt.media_id=s.media_id
  )
ORDER BY s.score DESC,s.media_id ASC
LIMIT $remaining;

SELECT
 COUNT(*) batch_count,
 COALESCE((SELECT score FROM fs_neighbor_seed_scan ORDER BY score ASC,media_id DESC LIMIT 1),0) last_score,
 COALESCE((SELECT media_id FROM fs_neighbor_seed_scan ORDER BY score ASC,media_id DESC LIMIT 1),0) last_media_id,
 changes() inserted_rows
FROM fs_neighbor_seed_scan;
COMMIT;
"@
        try{
            $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql $sql -ExecutionTimeoutMs 60000 -BusyRetries 0 -ProgressLabel ("Nachbar-Aufgaben vorbereiten | Batch {0}, {1}/{2} Seeds" -f $batchNo,($existing+$inserted),$max))
        }catch{
            if($_.Exception.Message -match 'SQLite-Ausführungszeit' -and $effectiveBatchSize -gt 100){
                $effectiveBatchSize=[Math]::Max(100,[int][Math]::Floor($effectiveBatchSize/2.0))
                $batchNo--
                Write-Host ("        [NEIGHBOR-SEED] SQL-Batch war zu groß; reduziere Scan auf {0} Medien." -f $effectiveBatchSize) -ForegroundColor DarkYellow
                continue
            }
            throw
        }
        if($rows.Count -eq 0){throw 'Nachbar-Seeding lieferte keine Batch-Statistik.'}
        $batchCount=[int]$rows[0].batch_count
        $nextScore=[int]$rows[0].last_score
        $nextMediaId=[long]$rows[0].last_media_id
        $insertedNow=[int]$rows[0].inserted_rows
        if($batchCount -le 0 -or $nextMediaId -le 0){break}
        $scanned+=$batchCount
        $inserted+=$insertedNow
        $cursorScore=$nextScore
        $cursorMediaId=$nextMediaId
        Write-Host ("        [NEIGHBOR-SEED] {0} Kandidaten geprüft; {1}/{2} Seeds vorhanden; {3} neu; Laufzeit {4}." -f $scanned,($existing+$inserted),$max,$inserted,(Format-FsSearchDuration $watch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
    }

    return [pscustomobject]@{
        Maximum=$max
        Existing=$existing
        Inserted=$inserted
        Scanned=$scanned
        SeedBatchSize=$effectiveBatchSize
        SeedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
    }
}


function Invoke-FsDownloadReuseFastPath {
    param(
        [int]$ProjectId,
        [hashtable]$Config,
        [string]$SqlitePath,
        [string]$DatabasePath
    )

    $batchSize=if($Config.Download.ContainsKey('ReuseBatchSize')){
        [Math]::Max(100,[Math]::Min(20000,[int]$Config.Download.ReuseBatchSize))
    }else{5000}
    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $directTotal=0
    $hashTotal=0
    $round=0

    # HF57: Project tasks whose exact global media row is already complete never
    # need a worker, HTTP gate or per-item finalize transaction. Mark them reused
    # in large batches before the worker queue starts.
    while($true){
        $round++
        [object[]]$rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 60000 -BusyRetries 3 -ProgressLabel ("Download-Reuse Fast-Path (direkt) | Batch {0}" -f $round) -Sql @"
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_download_reuse_direct;
CREATE TEMP TABLE fs_download_reuse_direct(media_id INTEGER PRIMARY KEY);
INSERT INTO fs_download_reuse_direct(media_id)
SELECT pd.media_id
FROM project_downloads pd INDEXED BY ix_project_downloads_queue
JOIN downloads d ON d.media_id=pd.media_id
JOIN media m ON m.id=pd.media_id
WHERE pd.project_id=$ProjectId
  AND pd.status IN ('pending','failed')
  AND d.status IN ('done','historical')
  AND d.historical_complete=1
  AND (
      m.sha1 IS NULL OR m.sha1=''
      OR d.verified_sha1 IS NULL OR d.verified_sha1=''
      OR lower(m.sha1)=lower(d.verified_sha1)
  )
ORDER BY pd.status,pd.media_id
LIMIT $batchSize;

UPDATE project_downloads
SET status='reused',
    lease_owner=NULL,
    lease_until=NULL,
    last_error=NULL,
    updated_at=$nowSql
WHERE project_id=$ProjectId
  AND media_id IN (SELECT media_id FROM fs_download_reuse_direct);

SELECT COUNT(*) reused_count FROM fs_download_reuse_direct;
DROP TABLE temp.fs_download_reuse_direct;
COMMIT;
"@)
        $count=if($rows.Count -gt 0){[int]$rows[-1].reused_count}else{0}
        if($count -le 0){break}
        $directTotal+=$count
    }

    # HF57: A second bulk path resolves media that share an already completed
    # SHA1 with another completed global download via downloads.verified_sha1.
    # This remains compatible with the unique media.sha1 identity index: the source
    # media row itself need not carry the same SHA1. Target rows are written in one
    # serialized transaction per batch.
    $round=0
    while($true){
        $round++
        [object[]]$rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 60000 -BusyRetries 3 -ProgressLabel ("Download-Reuse Fast-Path (SHA1) | Batch {0}" -f $round) -Sql @"
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_download_reuse_hash;
CREATE TEMP TABLE fs_download_reuse_hash(
    target_media_id INTEGER PRIMARY KEY,
    source_media_id INTEGER NOT NULL,
    source_status TEXT NOT NULL,
    local_path TEXT,
    bytes INTEGER,
    target_sha1 TEXT
);

INSERT OR IGNORE INTO fs_download_reuse_hash(
    target_media_id,source_media_id,source_status,local_path,bytes,target_sha1
)
SELECT pd.media_id,sd.media_id,sd.status,sd.local_path,sd.bytes,tm.sha1
FROM project_downloads pd INDEXED BY ix_project_downloads_queue
JOIN media tm ON tm.id=pd.media_id
JOIN downloads sd INDEXED BY ix_downloads_verified_sha1
  ON sd.verified_sha1=tm.sha1 COLLATE NOCASE
 AND sd.media_id<>tm.id
LEFT JOIN downloads td ON td.media_id=pd.media_id
WHERE pd.project_id=$ProjectId
  AND pd.status IN ('pending','failed')
  AND tm.sha1 IS NOT NULL AND tm.sha1<>''
  AND sd.verified_sha1 IS NOT NULL AND sd.verified_sha1<>''
  AND sd.status IN ('done','historical')
  AND sd.historical_complete=1
  AND (
      td.media_id IS NULL
      OR td.status IN ('pending','failed')
      OR (td.status='running' AND td.lease_until<=$nowSql)
  )
ORDER BY pd.status,pd.media_id,
         CASE WHEN sd.local_path IS NULL OR sd.local_path='' THEN 1 ELSE 0 END,
         sd.media_id
LIMIT $($batchSize*4);

INSERT INTO downloads(
    media_id,status,local_path,bytes,verified_sha1,historical_complete,
    owner_project_id,lease_owner,lease_until,attempts,last_error,created_at,updated_at
)
SELECT target_media_id,source_status,local_path,bytes,target_sha1,1,
       $ProjectId,NULL,NULL,0,NULL,$nowSql,$nowSql
FROM fs_download_reuse_hash
WHERE 1=1
ON CONFLICT(media_id) DO UPDATE SET
    status=excluded.status,
    local_path=excluded.local_path,
    bytes=excluded.bytes,
    verified_sha1=excluded.verified_sha1,
    historical_complete=1,
    owner_project_id=COALESCE(downloads.owner_project_id,excluded.owner_project_id),
    lease_owner=NULL,
    lease_until=NULL,
    last_error=NULL,
    updated_at=excluded.updated_at
WHERE downloads.status IN ('pending','failed')
   OR (downloads.status='running' AND downloads.lease_until<=$nowSql);

UPDATE project_downloads
SET status='reused',
    lease_owner=NULL,
    lease_until=NULL,
    last_error=NULL,
    updated_at=$nowSql
WHERE project_id=$ProjectId
  AND media_id IN (
      SELECT h.target_media_id
      FROM fs_download_reuse_hash h
      JOIN downloads d ON d.media_id=h.target_media_id
      WHERE d.status IN ('done','historical') AND d.historical_complete=1
  );

DELETE FROM fs_download_reuse_hash
WHERE target_media_id NOT IN (
    SELECT pd.media_id
    FROM project_downloads pd
    WHERE pd.project_id=$ProjectId AND pd.status='reused'
);

SELECT COUNT(*) reused_count FROM fs_download_reuse_hash;
DROP TABLE temp.fs_download_reuse_hash;
COMMIT;
"@)
        $count=if($rows.Count -gt 0){[int]$rows[-1].reused_count}else{0}
        if($count -le 0){break}
        $hashTotal+=$count
    }

    $total=$directTotal+$hashTotal
    if($total -gt 0){
        Write-Host ("        [DOWNLOAD-REUSE] {0} vorhandene Datei(en) vor der Worker-Queue in Bulk erledigt ({1} direkt, {2} per SHA1); Laufzeit {3}." -f $total,$directTotal,$hashTotal,(Format-FsSearchDuration $watch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
    }
    return [pscustomobject]@{
        Reused=$total
        Direct=$directTotal
        SameSha1=$hashTotal
        BatchSize=$batchSize
        Seconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
    }
}

function Repair-FsInvalidDownloadIdentityRows {
    param(
        [int]$ProjectId,
        [string]$SqlitePath,
        [string]$DatabasePath
    )

    # HF62: A media identity may have been merged/refreshed after an older
    # download was registered. If media.sha1 and downloads.verified_sha1 now
    # disagree, a terminal global row must not be treated as reusable. HF60
    # repeatedly claimed the project row while the terminal global row stayed
    # unowned, creating an endless pending/running loop. Reset only explicit
    # SHA1 mismatches; valid historical rows without a local file remain valid.
    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    [object[]]$rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 60000 -BusyRetries 3 -ProgressLabel 'Inkonsistente Download-Identitäten reparieren' -Sql @"
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_download_identity_repair;
CREATE TEMP TABLE fs_download_identity_repair(media_id INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO fs_download_identity_repair(media_id)
SELECT pd.media_id
FROM project_downloads pd INDEXED BY ix_project_downloads_queue
JOIN media m ON m.id=pd.media_id
JOIN downloads d ON d.media_id=pd.media_id
WHERE pd.project_id=$ProjectId
  AND pd.status IN ('pending','failed','running')
  AND d.status IN ('done','historical')
  AND m.sha1 IS NOT NULL AND m.sha1<>''
  AND d.verified_sha1 IS NOT NULL AND d.verified_sha1<>''
  AND lower(m.sha1)<>lower(d.verified_sha1);

UPDATE downloads
SET status='pending',
    local_path=NULL,
    bytes=NULL,
    verified_sha1=NULL,
    historical_complete=0,
    lease_owner=NULL,
    lease_until=NULL,
    attempts=0,
    last_error='HF62: gespeicherter Download passte nicht mehr zur aktuellen Medien-SHA1',
    updated_at=$nowSql
WHERE media_id IN (SELECT media_id FROM fs_download_identity_repair);

UPDATE project_downloads
SET status='pending',
    lease_owner=NULL,
    lease_until=NULL,
    attempts=0,
    last_error=NULL,
    updated_at=$nowSql
WHERE project_id=$ProjectId
  AND media_id IN (SELECT media_id FROM fs_download_identity_repair);

SELECT COUNT(*) repaired_count FROM fs_download_identity_repair;
DROP TABLE temp.fs_download_identity_repair;
COMMIT;
"@)
    $count=if($rows.Count -gt 0){[int]$rows[-1].repaired_count}else{0}
    if($count -gt 0){
        Write-Host ("        [DOWNLOAD-REPAIR] {0} inkonsistente Download-Identität(en) auf pending zurückgesetzt; erneuter Download wird erlaubt." -f $count) -ForegroundColor DarkYellow
    }
    return $count
}

function Seed-FsDownloadTasks {
    param(
        [int]$ProjectId,
        [hashtable]$Config,
        [string]$SqlitePath,
        [string]$DatabasePath
    )
    if((Get-FsPendingMediaIdentityConflictCount -SqlitePath $SqlitePath -DatabasePath $DatabasePath) -gt 0){
        [void](Repair-FsMediaIdentityConflicts -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MaxPairs 10000)
    }

    [void](Repair-FsInvalidDownloadIdentityRows -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $DatabasePath)

    # Preserve HF24's narrowly targeted repair of the old Task.Wait wrapper.
    $repairNow=Get-FsUtcNowText
    [object[]]$legacyDownloadRepair=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 60000 -BusyRetries 0 -ProgressLabel 'Legacy-Downloadfehler aus HF23 reaktivieren' -Sql @"
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_legacy_download_wait;
CREATE TEMP TABLE fs_legacy_download_wait(media_id INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO fs_legacy_download_wait(media_id)
SELECT media_id FROM project_downloads
WHERE project_id=$ProjectId AND status='failed'
  AND last_error LIKE 'Ausnahme beim Aufrufen von "Wait" mit 1 Argument(en):%';
UPDATE project_downloads SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$(ConvertTo-FsSqlLiteral $repairNow)
WHERE project_id=$ProjectId AND media_id IN (SELECT media_id FROM fs_legacy_download_wait);
UPDATE downloads SET status='pending',attempts=0,last_error=NULL,lease_owner=NULL,lease_until=NULL,updated_at=$(ConvertTo-FsSqlLiteral $repairNow)
WHERE media_id IN (SELECT media_id FROM fs_legacy_download_wait);
SELECT COUNT(*) repaired_count FROM fs_legacy_download_wait;
DROP TABLE temp.fs_legacy_download_wait;
COMMIT;
"@)
    if($legacyDownloadRepair.Count -gt 0 -and [int]$legacyDownloadRepair[-1].repaired_count -gt 0){
        Write-Host ("        [DOWNLOAD-REPAIR] {0} HF23-Wait-Fehler gezielt reaktiviert; andere finale Fehler bleiben unverändert." -f [int]$legacyDownloadRepair[-1].repaired_count) -ForegroundColor DarkYellow
    }

    $now=Get-FsUtcNowText
    $min=[int]$Config.Download.MinScore
    $seedBatchSize=if($Config.Download.ContainsKey('SeedBatchSize')){[Math]::Max(100,[int]$Config.Download.SeedBatchSize)}else{2000}
    $notRejected=Get-FsNotRejectedMediaSqlPredicate -Alias 'm'
    $watch=[Diagnostics.Stopwatch]::StartNew()

    # HF33 fast path: use only project_media rows that have not yet been marked
    # download_requested. Completed projects therefore avoid the former 71k-row
    # project_media/media/project_downloads scan entirely.
    [object[]]$candidateExistsRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 15000 -BusyRetries 0 -ProgressLabel 'Download-Fast-Path: neue Kandidaten prüfen' -Sql @"
SELECT EXISTS(
    SELECT 1
    FROM project_media pm INDEXED BY ix_project_media_download_seed
    JOIN media m ON m.id=pm.media_id
    WHERE pm.project_id=$ProjectId
      AND pm.selected=1
      AND pm.download_requested=0
      AND pm.score>=$min
      AND m.url IS NOT NULL AND m.url<>''
      AND (m.media_type IS NULL OR m.media_type='' OR m.media_type IN ('BITMAP','DRAWING'))
      AND ($notRejected)
      AND NOT EXISTS(
          SELECT 1 FROM project_downloads pd
          WHERE pd.project_id=$ProjectId AND pd.media_id=pm.media_id AND pd.status='skipped'
      )
    LIMIT 1
) candidate_exists;
"@)
    $candidateExists=if($candidateExistsRows.Count){[int]$candidateExistsRows[0].candidate_exists}else{1}
    if($candidateExists -eq 0){
        Write-Host ("        [DOWNLOAD-SEED] keine neuen Kandidaten mit Score >= {0}; kein Projektbestandsscan." -f $min) -ForegroundColor DarkGray
        [void](Invoke-FsDownloadReuseFastPath -ProjectId $ProjectId -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath)
        return [pscustomobject]@{Scanned=0;Candidates=0;Processed=0;SeedBatchSize=$seedBatchSize;SeedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2);FastPath=$true}
    }

    $processed=0;$batchNo=0
    while($true){
        $batchNo++
        $batchSql=@"
BEGIN IMMEDIATE;
CREATE TEMP TABLE fs_download_seed_batch(media_id INTEGER PRIMARY KEY);
INSERT INTO fs_download_seed_batch(media_id)
SELECT pm.media_id
FROM project_media pm INDEXED BY ix_project_media_download_seed
JOIN media m ON m.id=pm.media_id
WHERE pm.project_id=$ProjectId
  AND pm.selected=1
  AND pm.download_requested=0
  AND pm.score>=$min
  AND m.url IS NOT NULL AND m.url<>''
  AND (m.media_type IS NULL OR m.media_type='' OR m.media_type IN ('BITMAP','DRAWING'))
  AND ($notRejected)
  AND NOT EXISTS(
      SELECT 1 FROM project_downloads pd
      WHERE pd.project_id=$ProjectId AND pd.media_id=pm.media_id AND pd.status='skipped'
  )
ORDER BY pm.score DESC,pm.media_id ASC
LIMIT $seedBatchSize;
INSERT OR IGNORE INTO project_downloads(project_id,media_id,status,updated_at)
SELECT $ProjectId,media_id,'pending',$(ConvertTo-FsSqlLiteral $now) FROM fs_download_seed_batch;
UPDATE project_media
SET download_requested=1,updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND media_id IN (SELECT media_id FROM fs_download_seed_batch);
SELECT COUNT(*) candidate_count FROM fs_download_seed_batch;
COMMIT;
"@
        [object[]]$batchRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql $batchSql -ExecutionTimeoutMs 60000 -BusyRetries 0 -ProgressLabel ("Download-Kandidaten schreiben | Batch {0}; {1} verarbeitet" -f $batchNo,$processed))
        if($batchRows.Count -eq 0){throw 'Download-Seeding lieferte keine Batchstatistik.'}
        $batchCount=[int]$batchRows[0].candidate_count
        if($batchCount -le 0){break}
        $processed+=$batchCount
        Write-Host ("        [DOWNLOAD-SEED] {0} neue Kandidaten vorbereitet; Batch {1}; Laufzeit {2}." -f $processed,$batchNo,(Format-FsSearchDuration $watch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
    }

    [void](Invoke-FsDownloadReuseFastPath -ProjectId $ProjectId -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath)
    return [pscustomobject]@{Scanned=$processed;Candidates=$processed;Processed=$processed;SeedBatchSize=$seedBatchSize;SeedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2);FastPath=$false}
}

function Get-FsTaskMaxAttempts {
    param([hashtable]$Config)
    if($null -ne $Config -and $Config.ContainsKey('Task') -and $Config.Task.ContainsKey('MaxAttempts')){
        return [Math]::Max(1,[int]$Config.Task.MaxAttempts)
    }
    return 4
}

function Test-FsInfrastructureTaskError {
    param([string]$Message)
    if([string]::IsNullOrWhiteSpace($Message)){return $false}
    return ($Message -match '(?i)(database is locked|database is busy|SQLITE_BUSY|SQLITE_LOCKED|disk I/O error|SQLITE_IOERR|I/O error \(10\)|SQLite-Schreibsperre|SQLite-Ausführungszeit|Task-Lease.+verloren|Run \d+ ist nicht mehr aktiv|Download-Infrastruktur|(Eigenschaft|property)\s+["'']?(GateMs|HttpMs|Bytes|download_bytes)["'']?\s+(wurde.+nicht gefunden|cannot be found))')
}

function Reset-FsExpiredTasks {
    param(
        [int]$ProjectId,
        [string]$SqlitePath,
        [string]$DatabasePath,
        [ValidateSet('category','query','metadata','neighbor','download')][string]$Stage
    )
    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now

    # During a running stage, first perform a lock-free/read-only existence
    # check and update only the table(s) relevant to that stage. Hotfix 5
    # unconditionally touched every task table every 30 seconds, so even a
    # query-only run repeatedly competed with large query writes by issuing
    # UPDATE project_categories ... statements that changed zero rows.
    if(-not[string]::IsNullOrWhiteSpace($Stage)){
        $checks=@()
        switch($Stage){
            'category' {$checks=@(@{Table='project_categories';Where="project_id=$ProjectId"})}
            'query'    {$checks=@(@{Table='search_tasks';Where="project_id=$ProjectId"})}
            'metadata' {$checks=@(@{Table='metadata_tasks';Where="project_id=$ProjectId"})}
            'neighbor' {$checks=@(@{Table='neighbor_tasks';Where="project_id=$ProjectId"})}
            'download' {$checks=@(
                @{Table='project_downloads';Where="project_id=$ProjectId"},
                @{Table='downloads';Where="owner_project_id=$ProjectId"}
            )}
        }

        $reset=0
        foreach($check in $checks){
            $table=[string]$check.Table
            $where=[string]$check.Where
            $countRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT COUNT(*) count FROM $table WHERE $where AND status='running' AND lease_until<=$nowSql;")
            $count=if($countRows.Count -gt 0){[int]$countRows[0].count}else{0}
            if($count -le 0){continue}
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "UPDATE $table SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE $where AND status='running' AND lease_until<=$nowSql;"|Out-Null
            $reset+=$count
        }
        return $reset
    }

    # Startup/repair mode: all task tables are checked because no stage is
    # active yet. Each UPDATE is still guarded by a read-only existence check.
    $allChecks=@(
        @{Table='project_categories';Where="project_id=$ProjectId"},
        @{Table='search_tasks';Where="project_id=$ProjectId"},
        @{Table='metadata_tasks';Where="project_id=$ProjectId"},
        @{Table='neighbor_tasks';Where="project_id=$ProjectId"},
        @{Table='project_downloads';Where="project_id=$ProjectId"},
        @{Table='downloads';Where="owner_project_id=$ProjectId"}
    )
    $totalReset=0
    foreach($check in $allChecks){
        $table=[string]$check.Table
        $where=[string]$check.Where
        $countRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT COUNT(*) count FROM $table WHERE $where AND status='running' AND lease_until<=$nowSql;")
        $count=if($countRows.Count -gt 0){[int]$countRows[0].count}else{0}
        if($count -le 0){continue}
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "UPDATE $table SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,updated_at=$nowSql WHERE $where AND status='running' AND lease_until<=$nowSql;"|Out-Null
        $totalReset+=$count
    }
    return $totalReset
}

function Reset-FsProjectRunningTasks {
    param([int]$ProjectId,[string]$SqlitePath,[string]$DatabasePath)
    $now=Get-FsUtcNowText;$nowSql=ConvertTo-FsSqlLiteral $now
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
UPDATE project_categories SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running';
UPDATE search_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running';
UPDATE metadata_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running';
UPDATE neighbor_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running';
UPDATE project_downloads SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running';
UPDATE downloads SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$nowSql WHERE owner_project_id=$ProjectId AND status='running';
"@ | Out-Null
}

function Reset-FsWorkerTasks {
    param(
        [int]$ProjectId,
        [string]$Worker,
        [string]$SqlitePath,
        [string]$DatabasePath,
        [string]$Reason='Worker wurde beendet; Aufgabe erneut eingereiht.',
        [ValidateSet('','category','query','metadata','neighbor','download')][string]$Stage=''
    )
    if([string]::IsNullOrWhiteSpace($Worker)){return}
    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    $workerSql=ConvertTo-FsSqlLiteral $Worker
    $reasonSql=ConvertTo-FsSqlLiteral $Reason

    # HF55: a failed download worker must not scan/update every task table.
    # Restrict cleanup to the active stage whenever the caller knows it.
    # The empty-stage fallback preserves compatibility for maintenance/tests.
    $statements=New-Object Collections.Generic.List[string]
    switch($Stage){
        'category' {
            $statements.Add("UPDATE project_categories SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
        }
        'query' {
            $statements.Add("UPDATE search_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
        }
        'metadata' {
            $statements.Add("UPDATE metadata_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
        }
        'neighbor' {
            $statements.Add("UPDATE neighbor_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
        }
        'download' {
            $statements.Add("UPDATE project_downloads SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
            $statements.Add("UPDATE downloads SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE owner_project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
        }
        default {
            $statements.Add("UPDATE project_categories SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
            $statements.Add("UPDATE search_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
            $statements.Add("UPDATE metadata_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
            $statements.Add("UPDATE neighbor_tasks SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
            $statements.Add("UPDATE project_downloads SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
            $statements.Add("UPDATE downloads SET status='pending',attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,lease_owner=NULL,lease_until=NULL,last_error=$reasonSql,updated_at=$nowSql WHERE owner_project_id=$ProjectId AND status='running' AND lease_owner=$workerSql;")
        }
    }
    if($statements.Count -gt 0){
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql ($statements -join "`n") -ExecutionTimeoutMs 60000 -ProgressLabel ("Worker-Tasks freigeben: {0} / {1}" -f $(if([string]::IsNullOrWhiteSpace($Stage)){'alle Stufen'}else{$Stage}),$Worker) | Out-Null
    }
}

function Get-FsWorkerLeaseSeconds {
    param([string]$Stage,[hashtable]$Config)
    $retries=if($Config.ContainsKey('Api') -and $Config.Api.ContainsKey('Retries')){[int]$Config.Api.Retries}else{8}
    $apiBudget=[Math]::Max(3600,($retries*180)+600)
    switch($Stage){
        'neighbor' { return [Math]::Max($apiBudget,([int]$Config.Neighbors.MaxSecondsPerSeed+1800)) }
        'download' { return 14400 }
        default { return $apiBudget }
    }
}

function Renew-FsWorkerTasks {
    param(
        [int]$ProjectId,[string]$Stage,[string]$Worker,[int]$LeaseSeconds,
        [string]$SqlitePath,[string]$DatabasePath,[Nullable[int]]$RunId
    )
    $table = switch ($Stage) {
        'category' { 'project_categories' }
        'query'    { 'search_tasks' }
        'metadata' { 'metadata_tasks' }
        'neighbor' { 'neighbor_tasks' }
        'download' { 'project_downloads' }
        default    { throw "Unbekannte Stufe für Lease: $Stage" }
    }
    $now=Get-FsUtcNowText
    $lease=[DateTime]::UtcNow.AddSeconds([Math]::Max(60,$LeaseSeconds)).ToString('o')
    $workerSql=ConvertTo-FsSqlLiteral $Worker
    $runClause=if($null -ne $RunId){" AND EXISTS(SELECT 1 FROM runs WHERE id=$([int]$RunId) AND status='running')"}else{''}
    $downloadSql=if($Stage -eq 'download'){@"
UPDATE downloads
SET lease_until=$(ConvertTo-FsSqlLiteral $lease),updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE owner_project_id=$ProjectId AND status='running' AND lease_owner=$workerSql$runClause
  AND EXISTS(
      SELECT 1 FROM project_downloads pd
      WHERE pd.project_id=$ProjectId AND pd.status='running' AND pd.lease_owner=$workerSql
  );
"@}else{''}
    $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
BEGIN IMMEDIATE;
UPDATE $table
SET lease_until=$(ConvertTo-FsSqlLiteral $lease),updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND status='running' AND lease_owner=$workerSql$runClause
RETURNING rowid;
$downloadSql
COMMIT;
"@)
    return $rows.Count
}

function New-FsWorkerHeartbeat {
    param(
        [int]$ProjectId,[int]$RunId,[string]$Stage,[string]$Worker,[int]$LeaseSeconds,
        [string]$SqlitePath,[string]$DatabasePath,[int]$MinimumSeconds=60
    )
    # Claim-FsTask already grants a long lease. The old implementation renewed
    # it before/after nearly every API step, causing 5-8 sqlite3 processes per
    # ordinary query page. The closure below only touches the database after
    # the configured interval has actually elapsed. Run-active validation and
    # lease renewal are combined into that single SQL transaction.
    $heartbeatState=@{Last=[DateTime]::UtcNow}
    $minimum=[Math]::Max(15,$MinimumSeconds)
    return {
        $heartbeatNow=[DateTime]::UtcNow
        if(($heartbeatNow-$heartbeatState.Last).TotalSeconds -lt $minimum){return}
        $heartbeatState.Last=$heartbeatNow
        if((Renew-FsWorkerTasks -ProjectId $ProjectId -RunId $RunId -Stage $Stage -Worker $Worker -LeaseSeconds $LeaseSeconds -SqlitePath $SqlitePath -DatabasePath $DatabasePath) -lt 1){
            throw "Run $RunId ist nicht mehr aktiv oder die Task-Lease für Worker '$Worker' wurde verloren."
        }
    }.GetNewClosure()
}


function Claim-FsTask {
    param([string]$Table,[string]$KeyColumn,[int]$ProjectId,[string]$Worker,[string]$SqlitePath,[string]$DatabasePath,[int]$LeaseSeconds=600,[int]$Limit=1,[int]$MaxAttempts=4,[Nullable[int]]$RunId)
    $allowed=@('project_categories','search_tasks','metadata_tasks','neighbor_tasks','project_downloads','downloads')
    if($Table -notin $allowed){throw "Ungültige Task-Tabelle: $Table"}
    $now=Get-FsUtcNowText;$lease=[DateTime]::UtcNow.AddSeconds([Math]::Max(60,$LeaseSeconds)).ToString('o')
    $projectFilter=if($Table -eq 'downloads'){''}else{"project_id=$ProjectId AND "}
    $runFilter=if($null -ne $RunId){" AND EXISTS(SELECT 1 FROM runs WHERE id=$([int]$RunId) AND status='running')"}else{''}
    $order=if($Table -eq 'project_categories'){'depth,category_id'}else{'rowid'}
    $sql=@"
BEGIN IMMEDIATE;
UPDATE $Table
SET status='running',lease_owner=$(ConvertTo-FsSqlLiteral $Worker),lease_until=$(ConvertTo-FsSqlLiteral $lease),attempts=attempts+1,updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE rowid IN (
    SELECT rowid FROM $Table
    WHERE $projectFilter (status='pending' OR (status='failed' AND attempts<$MaxAttempts))$runFilter
    ORDER BY $order LIMIT $Limit
)
RETURNING *;
COMMIT;
"@
    return @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query)
}

function Complete-FsTask {
    param([string]$Table,[string]$Where,[string]$Status,[string]$SqlitePath,[string]$DatabasePath,[string]$Worker,[string]$Error,[string]$ContinuationJson,[hashtable]$Additional=@{})
    $allowed=@('project_categories','search_tasks','metadata_tasks','neighbor_tasks','project_downloads','downloads')
    if($Table -notin $allowed){throw "Ungültige Task-Tabelle: $Table"}
    $sets=New-Object Collections.Generic.List[string]
    $sets.Add("status=$(ConvertTo-FsSqlLiteral $Status)");$sets.Add('lease_owner=NULL');$sets.Add('lease_until=NULL');$sets.Add("last_error=$(ConvertTo-FsSqlLiteral $Error)")
    if($PSBoundParameters.ContainsKey('ContinuationJson')){$sets.Add("continuation_json=$(ConvertTo-FsSqlLiteral $ContinuationJson)")}
    foreach($key in $Additional.Keys){$sets.Add("$key=$(ConvertTo-FsSqlLiteral $Additional[$key])")}
    $sets.Add("updated_at=$(ConvertTo-FsSqlLiteral (Get-FsUtcNowText))")
    $ownerClause=if([string]::IsNullOrWhiteSpace($Worker)){''}else{" AND lease_owner=$(ConvertTo-FsSqlLiteral $Worker)"}
    $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql ("UPDATE $Table SET "+($sets -join ',')+" WHERE $Where$ownerClause RETURNING rowid;"))
    return ($rows.Count -gt 0)
}

function Test-FsCategoryAllowed {
    param([string]$Title,[int]$Depth,[hashtable]$CategoryConfig)
    if([string]$CategoryConfig.DriftGuard -in @('Off','Warn')){return $true}
    if($Depth -le [int]$CategoryConfig.PruneAfterDepth){return $true}
    $regex=[string]$CategoryConfig.ExcludeRegex
    if([string]::IsNullOrWhiteSpace($regex)){return $true}
    return -not ($Title -match $regex)
}

function Invoke-FsCategoryQueuePrune {
    param(
        [int]$ProjectId,
        [hashtable]$CategoryConfig,
        [string]$SqlitePath,
        [string]$DatabasePath
    )

    if($null -eq $CategoryConfig){return 0}
    if([string]$CategoryConfig.DriftGuard -notin @('Strict')){return 0}
    $regex=[string]$CategoryConfig.ExcludeRegex
    if([string]::IsNullOrWhiteSpace($regex)){return 0}
    $pruneAfter=[int]$CategoryConfig.PruneAfterDepth

    $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -ExecutionTimeoutMs 30000 -BusyRetries 0 -Sql @"
SELECT pc.category_id,c.title,pc.depth
FROM project_categories pc
JOIN categories c ON c.id=pc.category_id
WHERE pc.project_id=$ProjectId
  AND pc.status='pending'
  AND pc.depth>$pruneAfter;
"@)
    if($rows.Count -eq 0){return 0}

    $ids=New-Object Collections.Generic.List[int]
    foreach($row in $rows){
        $title=[string]$row.title
        if(-not[string]::IsNullOrWhiteSpace($title) -and $title -match $regex){$ids.Add([int]$row.category_id)}
    }
    if($ids.Count -eq 0){return 0}

    $nowSql=ConvertTo-FsSqlLiteral (Get-FsUtcNowText)
    $reasonSql=ConvertTo-FsSqlLiteral 'DriftGuard: vorhandene irrelevante Kategorie verworfen'
    for($offset=0;$offset -lt $ids.Count;$offset+=500){
        $take=[Math]::Min(500,$ids.Count-$offset)
        $chunk=New-Object Collections.Generic.List[string]
        for($i=0;$i -lt $take;$i++){$chunk.Add([string]$ids[$offset+$i])}
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ExecutionTimeoutMs 30000 -BusyRetries 0 -ProgressLabel 'CATEGORY-PRUNE' -Sql ("UPDATE project_categories SET status='skipped',last_error={0},lease_owner=NULL,lease_until=NULL,updated_at={1} WHERE project_id={2} AND status='pending' AND category_id IN ({3});" -f $reasonSql,$nowSql,$ProjectId,($chunk -join ',')) | Out-Null
    }
    return $ids.Count
}

function Invoke-FsCategoryResultBulkWrite {
    param(
        [int]$ProjectId,
        [object[]]$Items,
        [int]$ParentCategoryId,
        [string]$ParentTitle,
        [int]$Depth,
        [hashtable]$CategoryConfig,
        [string]$SqlitePath,
        [string]$DatabasePath
    )

    $transformWatch=[Diagnostics.Stopwatch]::StartNew()
    $rawInputCount=@($Items).Count
    $files=New-Object Collections.Generic.List[object]
    $children=New-Object Collections.Generic.List[object]
    $seenFiles=@{}
    $seenChildren=@{}
    $maxChildren=[int]$CategoryConfig.MaxChildrenPerCategory

    foreach($item in @($Items)){
        $ns=[int](Get-FsPropertyValue $item 'ns' -1)
        if($ns -eq 14){
            if($Depth -ge [int]$CategoryConfig.Depth){continue}
            if($children.Count -ge $maxChildren){continue}
            $child=Normalize-FsCategoryTitle ([string](Get-FsPropertyValue $item 'title'))
            if([string]::IsNullOrWhiteSpace($child)){continue}
            if(-not(Test-FsCategoryAllowed -Title $child -Depth ($Depth+1) -CategoryConfig $CategoryConfig)){continue}
            $norm=$child.ToLowerInvariant()
            if($seenChildren.ContainsKey($norm)){continue}
            $seenChildren[$norm]=$true
            $children.Add([pscustomobject]@{Title=$child;NormalizedTitle=$norm})
            continue
        }
        if($ns -ne 6){continue}
        $pageId=[long](Get-FsPropertyValue $item 'pageid' 0)
        $title=Normalize-FsFileTitle ([string](Get-FsPropertyValue $item 'title'))
        if($pageId -le 0 -or [string]::IsNullOrWhiteSpace($title)){continue}
        $key=[string]$pageId
        if($seenFiles.ContainsKey($key)){continue}
        $seenFiles[$key]=$true
        $files.Add([pscustomobject]@{PageId=$pageId;Title=$title;NormalizedTitle=(Normalize-FsMediaIdentityTitle $title)})
    }
    $transformMs=$transformWatch.Elapsed.TotalMilliseconds

    if($files.Count -eq 0 -and $children.Count -eq 0){
        return [pscustomobject]@{InputCount=$rawInputCount;Files=0;Children=0;NewProjectMedia=0;TransformMs=$transformMs;SqlBuildMs=0;BulkSqliteMs=0}
    }

    $sqlBuildWatch=[Diagnostics.Stopwatch]::StartNew()
    $fileValueStatements=New-Object Collections.Generic.List[string]
    for($offset=0;$offset -lt $files.Count;$offset+=250){
        $values=New-Object Collections.Generic.List[string]
        $take=[Math]::Min(250,$files.Count-$offset)
        for($i=0;$i -lt $take;$i++){
            $row=$files[$offset+$i]
            $values.Add(("({0},{1},{2})" -f [long]$row.PageId,(ConvertTo-FsSqlLiteral ([string]$row.Title)),(ConvertTo-FsSqlLiteral ([string]$row.NormalizedTitle))))
        }
        if($values.Count -gt 0){$fileValueStatements.Add("INSERT OR REPLACE INTO fs_category_files(page_id,title,normalized_title) VALUES`n"+($values -join ",`n")+";")}
    }
    $childValueStatements=New-Object Collections.Generic.List[string]
    for($offset=0;$offset -lt $children.Count;$offset+=250){
        $values=New-Object Collections.Generic.List[string]
        $take=[Math]::Min(250,$children.Count-$offset)
        for($i=0;$i -lt $take;$i++){
            $row=$children[$offset+$i]
            $values.Add(("({0},{1})" -f (ConvertTo-FsSqlLiteral ([string]$row.Title)),(ConvertTo-FsSqlLiteral ([string]$row.NormalizedTitle))))
        }
        if($values.Count -gt 0){$childValueStatements.Add("INSERT OR IGNORE INTO fs_category_children(title,normalized_title) VALUES`n"+($values -join ",`n")+";")}
    }

    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    $sourceSql=ConvertTo-FsSqlLiteral 'category'
    $parentTitleSql=ConvertTo-FsSqlLiteral $ParentTitle
    $score=[Math]::Max(45,90-($Depth*10))
    $childDepth=$Depth+1

    $sql=@"
PRAGMA temp_store=MEMORY;
PRAGMA cache_size=-65536;
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_category_files;
DROP TABLE IF EXISTS temp.fs_category_resolved;
DROP TABLE IF EXISTS temp.fs_category_existing_project;
DROP TABLE IF EXISTS temp.fs_category_children;
CREATE TEMP TABLE fs_category_files(
    page_id INTEGER PRIMARY KEY,
    title TEXT NOT NULL COLLATE NOCASE,
    normalized_title TEXT COLLATE NOCASE
);
CREATE TEMP TABLE fs_category_children(
    title TEXT NOT NULL,
    normalized_title TEXT PRIMARY KEY COLLATE NOCASE
);
$($fileValueStatements -join "`n")
$($childValueStatements -join "`n")

INSERT OR IGNORE INTO categories(title,normalized_title,created_at)
SELECT title,normalized_title,$nowSql FROM fs_category_children;

INSERT OR IGNORE INTO project_categories(
    project_id,category_id,parent_category_id,depth,status,discovered_at,updated_at
)
SELECT $ProjectId,c.id,$ParentCategoryId,$childDepth,'pending',$nowSql,$nowSql
FROM fs_category_children x
JOIN categories c ON c.normalized_title=x.normalized_title COLLATE NOCASE;

CREATE TEMP TABLE fs_category_resolved(
    page_id INTEGER PRIMARY KEY,
    title TEXT NOT NULL COLLATE NOCASE,
    normalized_title TEXT COLLATE NOCASE,
    media_id INTEGER
);
INSERT INTO fs_category_resolved(page_id,title,normalized_title,media_id)
SELECT r.page_id,r.title,r.normalized_title,
       COALESCE(
           (SELECT mi.media_id FROM media_identities mi WHERE mi.identity_type='pageid' AND mi.identity_value=CAST(r.page_id AS TEXT) LIMIT 1),
           (SELECT m.id FROM media m WHERE m.page_id=r.page_id ORDER BY m.id LIMIT 1),
           (SELECT m.id FROM media m WHERE m.title=r.title COLLATE NOCASE LIMIT 1)
       )
FROM fs_category_files r;

INSERT OR IGNORE INTO media(
    page_id,title,normalized_title,canonical_title,
    metadata_level,metadata_checked_level,created_at,updated_at
)
SELECT page_id,title,normalized_title,title,0,0,$nowSql,$nowSql
FROM fs_category_resolved
WHERE media_id IS NULL;

UPDATE fs_category_resolved
SET media_id=COALESCE(
       (SELECT mi.media_id FROM media_identities mi WHERE mi.identity_type='pageid' AND mi.identity_value=CAST(fs_category_resolved.page_id AS TEXT) LIMIT 1),
       (SELECT m.id FROM media m WHERE m.page_id=fs_category_resolved.page_id ORDER BY m.id LIMIT 1),
       (SELECT m.id FROM media m WHERE m.title=fs_category_resolved.title COLLATE NOCASE LIMIT 1)
    )
WHERE media_id IS NULL;
DELETE FROM fs_category_resolved WHERE media_id IS NULL;
CREATE INDEX fs_category_resolved_media ON fs_category_resolved(media_id);

DELETE FROM fs_category_resolved WHERE media_id IN (SELECT media_id FROM media_rejections WHERE media_id IS NOT NULL);
DELETE FROM fs_category_resolved WHERE page_id IN (SELECT page_id FROM media_rejections WHERE page_id IS NOT NULL AND page_id>0);
DELETE FROM fs_category_resolved
WHERE normalized_title IS NOT NULL AND normalized_title<>''
  AND EXISTS(SELECT 1 FROM media_rejections r WHERE r.normalized_title=fs_category_resolved.normalized_title COLLATE NOCASE);
DELETE FROM fs_category_resolved
WHERE media_id IN (
    SELECT m.id FROM media m JOIN media_rejections r ON r.sha1=m.sha1 COLLATE NOCASE
    WHERE m.sha1 IS NOT NULL AND m.sha1<>'' AND r.sha1 IS NOT NULL AND r.sha1<>''
);

CREATE TEMP TABLE fs_category_existing_project AS
SELECT r.page_id
FROM fs_category_resolved r
JOIN project_media pm ON pm.project_id=$ProjectId AND pm.media_id=r.media_id;
CREATE UNIQUE INDEX fs_category_existing_project_page ON fs_category_existing_project(page_id);

INSERT OR IGNORE INTO media_identity_conflicts(media_id_a,media_id_b,reason,created_at)
SELECT MIN(m.id,r.media_id),MAX(m.id,r.media_id),'category-pageid',$nowSql
FROM fs_category_resolved r
JOIN media m ON m.page_id=r.page_id
WHERE m.id<>r.media_id;

INSERT OR IGNORE INTO media_identity_conflicts(media_id_a,media_id_b,reason,created_at)
SELECT MIN(mi.media_id,r.media_id),MAX(mi.media_id,r.media_id),'category-title',$nowSql
FROM fs_category_resolved r
JOIN media_identities mi ON mi.identity_type='title' AND mi.identity_value=r.normalized_title COLLATE NOCASE
WHERE r.normalized_title IS NOT NULL AND r.normalized_title<>'' AND mi.media_id<>r.media_id;

INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'pageid',CAST(page_id AS TEXT),media_id,'category',$nowSql,$nowSql FROM fs_category_resolved;
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'title',normalized_title,media_id,'category',$nowSql,$nowSql FROM fs_category_resolved
WHERE normalized_title IS NOT NULL AND normalized_title<>'';

INSERT INTO project_media(project_id,media_id,score,best_source,selected,first_seen_at,updated_at)
SELECT DISTINCT $ProjectId,media_id,$score,$sourceSql,1,$nowSql,$nowSql
FROM fs_category_resolved
WHERE media_id IS NOT NULL
ON CONFLICT(project_id,media_id) DO UPDATE SET
    score=MAX(project_media.score,excluded.score),
    best_source=CASE WHEN excluded.score>=project_media.score THEN excluded.best_source ELSE project_media.best_source END,
    updated_at=excluded.updated_at
WHERE excluded.score>=project_media.score OR project_media.best_source IS NULL;

INSERT OR IGNORE INTO discoveries(
    project_id,media_id,source_type,source_value,score,language,query_text,
    origin_category_id,parent_media_id,details_json,created_at
)
SELECT DISTINCT $ProjectId,media_id,$sourceSql,$parentTitleSql,$score,NULL,NULL,
       $ParentCategoryId,NULL,NULL,$nowSql
FROM fs_category_resolved;

SELECT
 (SELECT COUNT(*) FROM fs_category_files) file_count,
 (SELECT COUNT(*) FROM fs_category_children) child_count,
 (SELECT COUNT(*) FROM fs_category_existing_project) existing_project_media,
 (SELECT COUNT(*) FROM fs_category_resolved)-(SELECT COUNT(*) FROM fs_category_existing_project) new_project_media;
DROP TABLE IF EXISTS temp.fs_category_existing_project;
DROP TABLE IF EXISTS temp.fs_category_resolved;
DROP TABLE IF EXISTS temp.fs_category_files;
DROP TABLE IF EXISTS temp.fs_category_children;
COMMIT;
"@
    $sqlBuildMs=$sqlBuildWatch.Elapsed.TotalMilliseconds
    $label=$ParentTitle
    if($label.Length -gt 60){$label=$label.Substring(0,60)+'...'}
    $bulkWatch=[Diagnostics.Stopwatch]::StartNew()
    $summary=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query -ExecutionTimeoutMs 120000 -BusyRetries 0 -ProgressLabel ("CATEGORY-BULK '{0}' ({1} Dateien/{2} Kinder)" -f $label,$files.Count,$children.Count))
    $bulkMs=$bulkWatch.Elapsed.TotalMilliseconds
    $newProjectMedia=if($summary.Count -gt 0){[int]$summary[-1].new_project_media}else{0}
    return [pscustomobject]@{InputCount=$rawInputCount;Files=$files.Count;Children=$children.Count;NewProjectMedia=$newProjectMedia;TransformMs=$transformMs;SqlBuildMs=$sqlBuildMs;BulkSqliteMs=$bulkMs}
}

function Invoke-FsCategoryWorkerItem {
    param([int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath,[hashtable]$Headers)
    $limits=Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT (SELECT COUNT(*) FROM project_categories WHERE project_id=$ProjectId) category_count,(SELECT COUNT(*) FROM project_media WHERE project_id=$ProjectId) files;"
    if([int]$limits[0].category_count -ge [int]$Config.Category.MaxCategories -or [int]$limits[0].files -ge [int]$Config.Category.MaxFiles){
        $reason=if([int]$limits[0].category_count -ge [int]$Config.Category.MaxCategories){'Kategorielimit erreicht'}else{'Dateilimit erreicht'}
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "UPDATE project_categories SET status='skipped',last_error=$(ConvertTo-FsSqlLiteral $reason),lease_owner=NULL,lease_until=NULL,updated_at=$(ConvertTo-FsSqlLiteral (Get-FsUtcNowText)) WHERE project_id=$ProjectId AND status='pending';"|Out-Null
        return $false
    }
    $leaseSeconds=Get-FsWorkerLeaseSeconds -Stage 'category' -Config $Config
    $task=@(Claim-FsTask -Table 'project_categories' -KeyColumn 'category_id' -ProjectId $ProjectId -Worker $Worker -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LeaseSeconds $leaseSeconds -Limit 1 -MaxAttempts (Get-FsTaskMaxAttempts -Config $Config) -RunId $RunId)
    if($task.Count -eq 0){return $false}
    $t=$task[0]
    $heartbeat=New-FsWorkerHeartbeat -ProjectId $ProjectId -RunId $RunId -Stage 'category' -Worker $Worker -LeaseSeconds $leaseSeconds -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MinimumSeconds $(if($Config.ContainsKey('Keyword') -and $Config.Keyword.ContainsKey('HeartbeatSeconds')){[int]$Config.Keyword.HeartbeatSeconds}else{60})
    $catRows=Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT title FROM categories WHERE id=$([int]$t.category_id);"
    $title=[string]$catRows[0].title
    $taskWatch=[Diagnostics.Stopwatch]::StartNew();$apiProfile=$null;$bulkProfile=$null;$completionMs=0.0
    try {
        & $heartbeat
        $parameters=@{action='query';list='categorymembers';cmtitle=$title;cmtype='file|subcat';cmlimit=500;cmprop='ids|title|type|timestamp'}
        if($t.continuation_json){$cont=[string]$t.continuation_json|ConvertFrom-Json;foreach($p in $cont.PSObject.Properties){$parameters[$p.Name]=$p.Value}}
        $response=Invoke-FsCommonsApi -Parameters $parameters -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs ([int]$Config.Api.DelayMs) -Retries ([int]$Config.Api.Retries) -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage 'category' -Heartbeat $heartbeat
        $apiProperty=$response.PSObject.Properties['__fs_profile'];if($null -ne $apiProperty){$apiProfile=$apiProperty.Value}
        $members=@($response.query.categorymembers)
        $bulkProfile=Invoke-FsCategoryResultBulkWrite -ProjectId $ProjectId -Items $members -ParentCategoryId ([int]$t.category_id) -ParentTitle $title -Depth ([int]$t.depth) -CategoryConfig $Config.Category -SqlitePath $SqlitePath -DatabasePath $DatabasePath
        & $heartbeat
        $next=if($response.PSObject.Properties['continue']){$response.continue|ConvertTo-Json -Compress}else{$null};$status=if($next){'pending'}else{'done'}
        $completeWatch=[Diagnostics.Stopwatch]::StartNew()
        [void](Complete-FsTask -Table 'project_categories' -Where "project_id=$ProjectId AND category_id=$([int]$t.category_id)" -Status $status -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -ContinuationJson $next -Additional @{member_count=([int]$t.member_count+[int]$bulkProfile.Files+[int]$bulkProfile.Children);file_count=([int]$t.file_count+[int]$bulkProfile.Files);child_count=([int]$t.child_count+[int]$bulkProfile.Children)})
        $completionMs=$completeWatch.Elapsed.TotalMilliseconds
        if(Test-FsDiagnosticsEnabled){
            $gateMs=if($null -ne $apiProfile){[double]$apiProfile.GateMs}else{0};$httpMs=if($null -ne $apiProfile){[double]$apiProfile.HttpParseMs}else{0}
            Write-FsPerformanceRecord -Record @{record_type='category';operation='category-page';task_id=[int]$t.category_id;query_text=$title;attempt=[int]$t.attempts;hits=[int]$bulkProfile.Files;input_count=[int]$bulkProfile.InputCount;unique_count=[int]$bulkProfile.Files;duplicate_count=0;new_project_media=[int]$bulkProfile.NewProjectMedia;gate_ms=$gateMs;http_parse_ms=$httpMs;transform_ms=[Math]::Round([double]$bulkProfile.TransformMs,3);sql_build_ms=[Math]::Round([double]$bulkProfile.SqlBuildMs,3);bulk_sqlite_ms=[Math]::Round([double]$bulkProfile.BulkSqliteMs,3);task_complete_ms=[Math]::Round($completionMs,3);total_ms=[Math]::Round($taskWatch.Elapsed.TotalMilliseconds,3);success=$true}
            if(Test-FsDiagnosticsConsoleEnabled){Write-Host ("[PROFILE] Category '{0}' | Gate {1:N0} ms | HTTP+JSON {2:N0} ms | Transform {3:N0} ms | SQL-Build {4:N0} ms | Bulk-DB {5:N0} ms | Abschluss {6:N0} ms | Gesamt {7:N0} ms | Dateien {8}; Kinder {9}" -f $title,$gateMs,$httpMs,[double]$bulkProfile.TransformMs,[double]$bulkProfile.SqlBuildMs,[double]$bulkProfile.BulkSqliteMs,$completionMs,$taskWatch.Elapsed.TotalMilliseconds,[int]$bulkProfile.Files,[int]$bulkProfile.Children)}
        }
        return $true
    } catch {
        if(Test-FsDiagnosticsEnabled){Write-FsPerformanceRecord -Record @{record_type='category';operation='category-page';task_id=[int]$t.category_id;query_text=$title;total_ms=[Math]::Round($taskWatch.Elapsed.TotalMilliseconds,3);success=$false;error=$_.Exception.Message}}
        if(Test-FsInfrastructureTaskError -Message $_.Exception.Message){throw}
        [void](Complete-FsTask -Table 'project_categories' -Where "project_id=$ProjectId AND category_id=$([int]$t.category_id)" -Status 'failed' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -Error $_.Exception.Message)
        return $true
    }
}
function Invoke-FsQueryResultBulkWrite {
    param(
        [int]$ProjectId,
        [object[]]$Items,
        [string]$TaskType,
        [string]$QueryText,
        [string]$Language,
        [int]$Score,
        [string]$SqlitePath,
        [string]$DatabasePath
    )

    $profileTransformWatch=[Diagnostics.Stopwatch]::StartNew()
    $rawInputCount=@($Items).Count
    $rows=New-Object Collections.Generic.List[object]
    $seen=@{}
    foreach($item in @($Items)){
        $pageId=[long](Get-FsPropertyValue $item 'pageid' 0)
        $title=Normalize-FsFileTitle ([string](Get-FsPropertyValue $item 'title'))
        if($pageId -le 0 -or [string]::IsNullOrWhiteSpace($title)){continue}
        $key=[string]$pageId
        if($seen.ContainsKey($key)){continue}
        $seen[$key]=$true
        $normalized=Normalize-FsMediaIdentityTitle $title
        $rows.Add([pscustomobject]@{PageId=$pageId;Title=$title;NormalizedTitle=$normalized})
    }
    $profileTransformMs=$profileTransformWatch.Elapsed.TotalMilliseconds
    if($rows.Count -eq 0){return [pscustomobject]@{Written=0;InputCount=$rawInputCount;UniqueCount=0;DuplicateCount=$rawInputCount;NewProjectMedia=0;TransformMs=$profileTransformMs;SqlBuildMs=0;BulkSqliteMs=0}}

    $profileSqlBuildWatch=[Diagnostics.Stopwatch]::StartNew()
    $valueStatements=New-Object Collections.Generic.List[string]
    $valueChunkSize=250
    for($offset=0;$offset -lt $rows.Count;$offset+=$valueChunkSize){
        $values=New-Object Collections.Generic.List[string]
        foreach($row in @($rows|Select-Object -Skip $offset -First $valueChunkSize)){
            $values.Add(("({0},{1},{2})" -f [long]$row.PageId,(ConvertTo-FsSqlLiteral ([string]$row.Title)),(ConvertTo-FsSqlLiteral ([string]$row.NormalizedTitle))))
        }
        $valueStatements.Add("INSERT OR REPLACE INTO fs_query_results(page_id,title,normalized_title) VALUES`n"+($values -join ",`n")+";")
    }

    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    $sourceTypeSql=ConvertTo-FsSqlLiteral $TaskType
    $queryTextSql=ConvertTo-FsSqlLiteral $QueryText
    $languageSql=ConvertTo-FsSqlLiteral $Language

    # Hotfix 8: page_id is the authoritative identity for Wikimedia query hits.
    # Resolution is intentionally split into independent indexed lookups. The
    # former OR predicates forced correlated full scans of media and could run
    # for more than 300 seconds on a 58k-row workspace.
    $sql=@"
PRAGMA temp_store=MEMORY;
PRAGMA cache_size=-65536;
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_query_results;
DROP TABLE IF EXISTS temp.fs_query_resolved;
DROP TABLE IF EXISTS temp.fs_query_existing_project;
CREATE TEMP TABLE fs_query_results(
    page_id INTEGER PRIMARY KEY,
    title TEXT NOT NULL COLLATE NOCASE,
    normalized_title TEXT COLLATE NOCASE
);
$($valueStatements -join "`n")

CREATE TEMP TABLE fs_query_resolved(
    page_id INTEGER PRIMARY KEY,
    title TEXT NOT NULL COLLATE NOCASE,
    normalized_title TEXT COLLATE NOCASE,
    media_id INTEGER
);
INSERT INTO fs_query_resolved(page_id,title,normalized_title,media_id)
SELECT r.page_id,r.title,r.normalized_title,
       COALESCE(
           (SELECT mi.media_id
              FROM media_identities mi
             WHERE mi.identity_type='pageid'
               AND mi.identity_value=CAST(r.page_id AS TEXT)
             LIMIT 1),
           (SELECT m.id
              FROM media m
             WHERE m.page_id=r.page_id
             ORDER BY m.id
             LIMIT 1),
           (SELECT m.id
              FROM media m
             WHERE m.title=r.title COLLATE NOCASE
             LIMIT 1)
       )
FROM fs_query_results r;

INSERT OR IGNORE INTO media(
    page_id,title,normalized_title,canonical_title,
    metadata_level,metadata_checked_level,created_at,updated_at
)
SELECT page_id,title,normalized_title,title,0,0,$nowSql,$nowSql
FROM fs_query_resolved
WHERE media_id IS NULL;

UPDATE fs_query_resolved
SET media_id=COALESCE(
       (SELECT mi.media_id
          FROM media_identities mi
         WHERE mi.identity_type='pageid'
           AND mi.identity_value=CAST(fs_query_resolved.page_id AS TEXT)
         LIMIT 1),
       (SELECT m.id
          FROM media m
         WHERE m.page_id=fs_query_resolved.page_id
         ORDER BY m.id
         LIMIT 1),
       (SELECT m.id
          FROM media m
         WHERE m.title=fs_query_resolved.title COLLATE NOCASE
         LIMIT 1)
    )
WHERE media_id IS NULL;
DELETE FROM fs_query_resolved WHERE media_id IS NULL;
CREATE INDEX fs_query_resolved_media ON fs_query_resolved(media_id);

-- Hotfix 11: global review rejections are checked by four independent indexed
-- identity paths. A result may still refresh the global media row, but it can no
-- longer re-enter a project or its download queue through another query.
DELETE FROM fs_query_resolved WHERE media_id IN (SELECT media_id FROM media_rejections WHERE media_id IS NOT NULL);
DELETE FROM fs_query_resolved WHERE page_id IN (SELECT page_id FROM media_rejections WHERE page_id IS NOT NULL AND page_id>0);
DELETE FROM fs_query_resolved
WHERE normalized_title IS NOT NULL AND normalized_title<>''
  AND EXISTS(SELECT 1 FROM media_rejections r WHERE r.normalized_title=fs_query_resolved.normalized_title COLLATE NOCASE);
DELETE FROM fs_query_resolved
WHERE media_id IN (
    SELECT m.id FROM media m JOIN media_rejections r ON r.sha1=m.sha1 COLLATE NOCASE
    WHERE m.sha1 IS NOT NULL AND m.sha1<>'' AND r.sha1 IS NOT NULL AND r.sha1<>''
);

CREATE TEMP TABLE fs_query_existing_project AS
SELECT r.page_id
FROM fs_query_resolved r
JOIN project_media pm
  ON pm.project_id=$ProjectId
 AND pm.media_id=r.media_id;
CREATE UNIQUE INDEX fs_query_existing_project_page ON fs_query_existing_project(page_id);

INSERT OR IGNORE INTO media_identity_conflicts(media_id_a,media_id_b,reason,created_at)
SELECT MIN(m.id,r.media_id),MAX(m.id,r.media_id),'query-pageid',$nowSql
FROM fs_query_resolved r
JOIN media m ON m.page_id=r.page_id
WHERE m.id<>r.media_id;

INSERT OR IGNORE INTO media_identity_conflicts(media_id_a,media_id_b,reason,created_at)
SELECT MIN(mi.media_id,r.media_id),MAX(mi.media_id,r.media_id),'query-title',$nowSql
FROM fs_query_resolved r
JOIN media_identities mi
  ON mi.identity_type='title'
 AND mi.identity_value=r.normalized_title COLLATE NOCASE
WHERE r.normalized_title IS NOT NULL
  AND r.normalized_title<>''
  AND mi.media_id<>r.media_id;

INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'pageid',CAST(page_id AS TEXT),media_id,'query',$nowSql,$nowSql
FROM fs_query_resolved;

INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'title',normalized_title,media_id,'query',$nowSql,$nowSql
FROM fs_query_resolved
WHERE normalized_title IS NOT NULL AND normalized_title<>'';

INSERT INTO project_media(project_id,media_id,score,best_source,selected,first_seen_at,updated_at)
SELECT DISTINCT $ProjectId,media_id,$Score,$sourceTypeSql,1,$nowSql,$nowSql
FROM fs_query_resolved
WHERE media_id IS NOT NULL
ON CONFLICT(project_id,media_id) DO UPDATE SET
    score=MAX(project_media.score,excluded.score),
    best_source=CASE WHEN excluded.score>project_media.score OR project_media.best_source IS NULL THEN excluded.best_source ELSE project_media.best_source END,
    updated_at=excluded.updated_at
WHERE excluded.score>project_media.score
   OR project_media.best_source IS NULL;

INSERT OR IGNORE INTO discoveries(
    project_id,media_id,source_type,source_value,score,language,query_text,
    origin_category_id,parent_media_id,details_json,created_at
)
SELECT DISTINCT $ProjectId,media_id,$sourceTypeSql,$queryTextSql,$Score,$languageSql,$queryTextSql,
       NULL,NULL,NULL,$nowSql
FROM fs_query_resolved;

SELECT
 (SELECT COUNT(*) FROM fs_query_results) input_count,
 (SELECT COUNT(*) FROM fs_query_existing_project) existing_project_media,
 (SELECT COUNT(*) FROM fs_query_resolved)-(SELECT COUNT(*) FROM fs_query_existing_project) new_project_media;
DROP TABLE IF EXISTS temp.fs_query_existing_project;
DROP TABLE IF EXISTS temp.fs_query_resolved;
DROP TABLE IF EXISTS temp.fs_query_results;
COMMIT;
"@

    $profileSqlBuildMs=$profileSqlBuildWatch.Elapsed.TotalMilliseconds
    $label=$QueryText
    if($label.Length -gt 60){$label=$label.Substring(0,60)+'...'}
    $profileBulkWatch=[Diagnostics.Stopwatch]::StartNew()
    $bulkSummary=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql -Query -ExecutionTimeoutMs 120000 -BusyRetries 0 -ProgressLabel ("QUERY-BULK '{0}' ({1} Treffer)" -f $label,$rows.Count))
    $profileBulkMs=$profileBulkWatch.Elapsed.TotalMilliseconds
    $newProjectMedia=if($bulkSummary.Count -gt 0){[int]$bulkSummary[-1].new_project_media}else{0}
    return [pscustomobject]@{Written=$rows.Count;InputCount=$rawInputCount;UniqueCount=$rows.Count;DuplicateCount=[Math]::Max(0,$rawInputCount-$rows.Count);NewProjectMedia=$newProjectMedia;TransformMs=$profileTransformMs;SqlBuildMs=$profileSqlBuildMs;BulkSqliteMs=$profileBulkMs}
}

function Invoke-FsQueryWorkerItem {
    param([int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath,[hashtable]$Headers)
    $fileCountRows=Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT COUNT(*) count FROM project_media WHERE project_id=$ProjectId;"
    if([int]$fileCountRows[0].count -ge [int]$Config.Category.MaxFiles){Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "UPDATE search_tasks SET status='skipped',last_error='Dateilimit erreicht',lease_owner=NULL,lease_until=NULL,updated_at=$(ConvertTo-FsSqlLiteral (Get-FsUtcNowText)) WHERE project_id=$ProjectId AND status='pending';"|Out-Null;return $false}
    $leaseSeconds=Get-FsWorkerLeaseSeconds -Stage 'query' -Config $Config
    $task=@(Claim-FsTask -Table 'search_tasks' -KeyColumn 'id' -ProjectId $ProjectId -Worker $Worker -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LeaseSeconds $leaseSeconds -Limit 1 -MaxAttempts (Get-FsTaskMaxAttempts -Config $Config) -RunId $RunId)
    if($task.Count -eq 0){return $false}
    $t=$task[0]
    $heartbeat=New-FsWorkerHeartbeat -ProjectId $ProjectId -RunId $RunId -Stage 'query' -Worker $Worker -LeaseSeconds $leaseSeconds -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MinimumSeconds $(if($Config.ContainsKey('Keyword') -and $Config.Keyword.ContainsKey('HeartbeatSeconds')){[int]$Config.Keyword.HeartbeatSeconds}else{60})
    $taskWatch=[Diagnostics.Stopwatch]::StartNew();$apiProfile=$null;$bulkProfile=$null;$completionMs=0.0
    try {
        & $heartbeat
        $remaining=[int]$t.max_results-[int]$t.results_count
        if($remaining -le 0){[void](Complete-FsTask -Table 'search_tasks' -Where "id=$([int]$t.id)" -Status 'done' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker);return $true}
        $parameters=@{action='query';list='search';srnamespace=6;srsearch=[string]$t.query_text;srlimit=[Math]::Min(500,$remaining)}
        if($t.continuation_json){$cont=[string]$t.continuation_json|ConvertFrom-Json;foreach($p in $cont.PSObject.Properties){$parameters[$p.Name]=$p.Value}}
        $response=Invoke-FsCommonsApi -Parameters $parameters -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs ([int]$Config.Api.DelayMs) -Retries ([int]$Config.Api.Retries) -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage 'query' -Heartbeat $heartbeat
        $apiProperty=$response.PSObject.Properties['__fs_profile'];if($null -ne $apiProperty){$apiProfile=$apiProperty.Value}
        $bulkProfile=Invoke-FsQueryResultBulkWrite -ProjectId $ProjectId -Items @($response.query.search) -TaskType ([string]$t.task_type) -QueryText ([string]$t.query_text) -Language ([string]$t.language) -Score ([int]$t.score) -SqlitePath $SqlitePath -DatabasePath $DatabasePath
        & $heartbeat
        $newCount=[int]$t.results_count+[int]$bulkProfile.Written;$next=if($response.PSObject.Properties['continue'] -and $newCount -lt [int]$t.max_results){$response.continue|ConvertTo-Json -Compress}else{$null};$status=if($next){'pending'}else{'done'}
        $completeWatch=[Diagnostics.Stopwatch]::StartNew()
        [void](Complete-FsTask -Table 'search_tasks' -Where "id=$([int]$t.id)" -Status $status -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -ContinuationJson $next -Additional @{results_count=$newCount})
        $completionMs=$completeWatch.Elapsed.TotalMilliseconds
        if(Test-FsDiagnosticsEnabled){
            $gateMs=if($null -ne $apiProfile){[double]$apiProfile.GateMs}else{0};$httpMs=if($null -ne $apiProfile){[double]$apiProfile.HttpParseMs}else{0}
            Write-FsPerformanceRecord -Record @{record_type='query';operation='query-page';task_id=[int]$t.id;query_text=[string]$t.query_text;language=[string]$t.language;attempt=[int]$t.attempts;hits=[int]$bulkProfile.Written;input_count=[int]$bulkProfile.InputCount;unique_count=[int]$bulkProfile.UniqueCount;duplicate_count=[int]$bulkProfile.DuplicateCount;new_project_media=[int]$bulkProfile.NewProjectMedia;gate_ms=$gateMs;http_parse_ms=$httpMs;transform_ms=[Math]::Round([double]$bulkProfile.TransformMs,3);sql_build_ms=[Math]::Round([double]$bulkProfile.SqlBuildMs,3);bulk_sqlite_ms=[Math]::Round([double]$bulkProfile.BulkSqliteMs,3);task_complete_ms=[Math]::Round($completionMs,3);total_ms=[Math]::Round($taskWatch.Elapsed.TotalMilliseconds,3);success=$true}
            if(Test-FsDiagnosticsConsoleEnabled){Write-Host ("[PROFILE] Query '{0}' | Gate {1:N0} ms | HTTP+JSON {2:N0} ms | Transform {3:N0} ms | SQL-Build {4:N0} ms | Bulk-DB {5:N0} ms | Abschluss {6:N0} ms | Gesamt {7:N0} ms | Treffer {8}; neu im Projekt {9}" -f [string]$t.query_text,$gateMs,$httpMs,[double]$bulkProfile.TransformMs,[double]$bulkProfile.SqlBuildMs,[double]$bulkProfile.BulkSqliteMs,$completionMs,$taskWatch.Elapsed.TotalMilliseconds,[int]$bulkProfile.Written,[int]$bulkProfile.NewProjectMedia)}
        }
        return $true
    } catch {
        if(Test-FsDiagnosticsEnabled){Write-FsPerformanceRecord -Record @{record_type='query';operation='query-page';task_id=[int]$t.id;query_text=[string]$t.query_text;language=[string]$t.language;total_ms=[Math]::Round($taskWatch.Elapsed.TotalMilliseconds,3);success=$false;error=$_.Exception.Message}}
        if(Test-FsInfrastructureTaskError -Message $_.Exception.Message){throw};[void](Complete-FsTask -Table 'search_tasks' -Where "id=$([int]$t.id)" -Status 'failed' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -Error $_.Exception.Message);return $true
    }
}

function Get-FsMetadataResponseCollections {
    param($Response)

    # Windows PowerShell 5.1 can collapse an empty array emitted from an
    # if/else script block to $null. Initialise strongly typed arrays first so
    # callers always receive stable Object[] properties, even when MediaWiki
    # omits query, pages or redirects completely.
    [object[]]$pages=@()
    [object[]]$redirects=@()

    $queryNode=Get-FsPropertyValue -Object $Response -Name 'query'
    if($null -ne $queryNode){
        $pagesNode=Get-FsPropertyValue -Object $queryNode -Name 'pages'
        $redirectsNode=Get-FsPropertyValue -Object $queryNode -Name 'redirects'
        if($null -ne $pagesNode){$pages=[object[]]@($pagesNode)}
        if($null -ne $redirectsNode){$redirects=[object[]]@($redirectsNode)}
    }

    return [pscustomobject]@{
        Pages=$pages
        Redirects=$redirects
    }
}

function Test-FsUriTooLongError {
    param([string]$Message)
    if([string]::IsNullOrWhiteSpace($Message)){return $false}
    return ($Message -match '(?i)\(414\)|URI Too Long|Request-URI Too Large|Request URI is too long')
}

function Get-FsMetadataRequestGroups {
    param(
        [object[]]$Tasks,
        [object[]]$MediaRows,
        [ValidateRange(1,50)][int]$MaxTitles=50,
        [ValidateRange(1000,12000)][int]$MaxEncodedTitleChars=3500
    )

    $rowById=@{}
    foreach($row in @($MediaRows)){$rowById[[int]$row.id]=$row}

    $pageEntries=New-Object Collections.ArrayList
    $titleEntries=New-Object Collections.ArrayList
    $missingIds=New-Object Collections.ArrayList
    foreach($task in @($Tasks)){
        $taskId=[int]$task.media_id
        if(-not $rowById.ContainsKey($taskId)){
            [void]$missingIds.Add($taskId)
            continue
        }
        $row=$rowById[$taskId]
        $entry=[pscustomobject]@{Task=$task;Row=$row}
        if([long]$row.page_id -gt 0){[void]$pageEntries.Add($entry)}
        elseif(-not[string]::IsNullOrWhiteSpace([string]$row.request_title)){[void]$titleEntries.Add($entry)}
        else{[void]$missingIds.Add($taskId)}
    }

    $groups=New-Object Collections.ArrayList

    # Page IDs are short, canonical and unaffected by unusual or very long
    # Commons titles. They keep a normal 50-item metadata request comfortably
    # below common HTTP request-line limits.
    for($offset=0;$offset -lt $pageEntries.Count;$offset+=50){
        $take=[Math]::Min(50,$pageEntries.Count-$offset)
        $groupTasks=New-Object Collections.ArrayList
        $groupRows=New-Object Collections.ArrayList
        for($i=0;$i -lt $take;$i++){
            $entry=$pageEntries[$offset+$i]
            [void]$groupTasks.Add($entry.Task)
            [void]$groupRows.Add($entry.Row)
        }
        [void]$groups.Add([pscustomobject]@{Mode='pageids';Tasks=[object[]]($groupTasks.ToArray());Rows=[object[]]($groupRows.ToArray())})
    }

    # A title fallback is required only for legacy/imported records without a
    # Commons page ID. Split by both MediaWiki's item limit and the encoded URI
    # contribution so GET requests stay safely below proxy/server limits.
    $currentTasks=New-Object Collections.ArrayList
    $currentRows=New-Object Collections.ArrayList
    $currentEncodedLength=0
    foreach($entry in @($titleEntries)){
        $title=[string]$entry.Row.request_title
        try{$encodedLength=([Uri]::EscapeDataString($title)).Length}catch{$encodedLength=($title.Length*3)}
        $separatorLength=if($currentTasks.Count -gt 0){3}else{0}
        $wouldOverflow=($currentTasks.Count -ge $MaxTitles) -or (($currentEncodedLength+$separatorLength+$encodedLength) -gt $MaxEncodedTitleChars -and $currentTasks.Count -gt 0)
        if($wouldOverflow){
            [void]$groups.Add([pscustomobject]@{Mode='titles';Tasks=[object[]]($currentTasks.ToArray());Rows=[object[]]($currentRows.ToArray())})
            $currentTasks=New-Object Collections.ArrayList
            $currentRows=New-Object Collections.ArrayList
            $currentEncodedLength=0
            $separatorLength=0
        }
        [void]$currentTasks.Add($entry.Task)
        [void]$currentRows.Add($entry.Row)
        $currentEncodedLength+=$separatorLength+$encodedLength
    }
    if($currentTasks.Count -gt 0){
        [void]$groups.Add([pscustomobject]@{Mode='titles';Tasks=[object[]]($currentTasks.ToArray());Rows=[object[]]($currentRows.ToArray())})
    }

    return [pscustomobject]@{
        Groups=[object[]]($groups.ToArray())
        MissingTaskIds=[object[]]($missingIds.ToArray())
    }
}

function Set-FsMetadataBatchFailure {
    param(
        [object[]]$Tasks,[int]$ProjectId,[string]$Worker,[string]$Message,
        [string]$SqlitePath,[string]$DatabasePath
    )
    $ids=@($Tasks|ForEach-Object{[int]$_.media_id})
    if($ids.Count -eq 0){return}
    $idList=$ids -join ','
    $now=Get-FsUtcNowText
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
UPDATE metadata_tasks
SET status='failed',
    lease_owner=NULL,
    lease_until=NULL,
    last_error=$(ConvertTo-FsSqlLiteral $Message),
    updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId
  AND media_id IN ($idList)
  AND status='running'
  AND lease_owner=$(ConvertTo-FsSqlLiteral $Worker);
"@ | Out-Null
}

function Invoke-FsMetadataRequestGroup {
    param(
        [Parameter(Mandatory=$true)]$Group,
        [int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath,[hashtable]$Headers,
        [scriptblock]$Heartbeat
    )

    [object[]]$groupTasks=@($Group.Tasks)
    [object[]]$groupRows=@($Group.Rows)
    if($groupTasks.Count -eq 0){return}

    $parameters=@{
        action='query'
        prop='imageinfo|coordinates'
        iiprop='url|size|sha1|mime|mediatype|user|timestamp|metadata|extmetadata'
        iilimit=1
        coprop='type|name|dim|country|region'
        colimit=1
    }
    if(([string]$Group.Mode) -eq 'pageids'){
        $parameters.pageids=(@($groupRows|ForEach-Object{[string]([long]$_.page_id)})) -join '|'
    }else{
        $parameters.redirects=1
        $parameters.titles=(@($groupRows|ForEach-Object{[string]$_.request_title})) -join '|'
    }

    try{
        if($null -ne $Heartbeat){& $Heartbeat}
        $response=Invoke-FsCommonsApi -Parameters $parameters -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs ([int]$Config.Api.DelayMs) -Retries ([int]$Config.Api.Retries) -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage 'metadata' -Heartbeat $Heartbeat
    }catch{
        $msg=[string]$_.Exception.Message
        if(Test-FsInfrastructureTaskError -Message $msg){throw}
        if((Test-FsUriTooLongError -Message $msg) -and $groupTasks.Count -gt 1){
            $leftCount=[int][Math]::Floor($groupTasks.Count/2.0)
            $rightCount=$groupTasks.Count-$leftCount
            $leftTasks=New-Object Collections.ArrayList;$leftRows=New-Object Collections.ArrayList
            $rightTasks=New-Object Collections.ArrayList;$rightRows=New-Object Collections.ArrayList
            for($i=0;$i -lt $groupTasks.Count;$i++){
                if($i -lt $leftCount){[void]$leftTasks.Add($groupTasks[$i]);[void]$leftRows.Add($groupRows[$i])}
                else{[void]$rightTasks.Add($groupTasks[$i]);[void]$rightRows.Add($groupRows[$i])}
            }
            Write-Host ("        [METADATA] HTTP 414 bei {0} {1}; teile sofort in {2}+{3}." -f $groupTasks.Count,$Group.Mode,$leftCount,$rightCount) -ForegroundColor DarkYellow
            Invoke-FsMetadataRequestGroup -Group ([pscustomobject]@{Mode=$Group.Mode;Tasks=[object[]]($leftTasks.ToArray());Rows=[object[]]($leftRows.ToArray())}) -ProjectId $ProjectId -RunId $RunId -Worker $Worker -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Headers $Headers -Heartbeat $Heartbeat
            Invoke-FsMetadataRequestGroup -Group ([pscustomobject]@{Mode=$Group.Mode;Tasks=[object[]]($rightTasks.ToArray());Rows=[object[]]($rightRows.ToArray())}) -ProjectId $ProjectId -RunId $RunId -Worker $Worker -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Headers $Headers -Heartbeat $Heartbeat
            return
        }
        Set-FsMetadataBatchFailure -Tasks $groupTasks -ProjectId $ProjectId -Worker $Worker -Message $msg -SqlitePath $SqlitePath -DatabasePath $DatabasePath
        Write-Host ("        [METADATA-FEHLER] Teilbatch mit {0} Medium/Medien ({1}): {2}" -f $groupTasks.Count,$Group.Mode,$msg) -ForegroundColor DarkYellow
        return
    }

    $now=Get-FsUtcNowText
    $statements=New-Object Collections.Generic.List[string]
    $seenTitles=@{}
    $seenPageIds=@{}
    $workerSql=ConvertTo-FsSqlLiteral $Worker
    $metadataResponse=Get-FsMetadataResponseCollections -Response $response
    foreach($page in @($metadataResponse.Pages)){
        $record=Convert-FsImageInfoRecord $page
        if($null -eq $record){continue}
        $record | Add-Member -NotePropertyName MetadataLevel -NotePropertyValue ([int]$Config.Metadata.Level) -Force
        $record | Add-Member -NotePropertyName MetadataCheckedLevel -NotePropertyValue ([int]$Config.Metadata.Level) -Force
        $seenTitles[(Normalize-FsMediaIdentityTitle $record.Title)]=$true
        if([long]$record.PageId -gt 0){$seenPageIds[[string]([long]$record.PageId)]=$true}
        $statements.Add((Get-FsMediaInsertSql $record $now))
    }
    foreach($redirect in @($metadataResponse.Redirects)){
        $fromKey=Normalize-FsMediaIdentityTitle ([string](Get-FsPropertyValue -Object $redirect -Name 'from'))
        $toKey=Normalize-FsMediaIdentityTitle ([string](Get-FsPropertyValue -Object $redirect -Name 'to'))
        if($fromKey -and $toKey -and $seenTitles.ContainsKey($toKey)){$seenTitles[$fromKey]=$true}
    }

    $rowById=@{}
    foreach($row in $groupRows){$rowById[[int]$row.id]=$row}
    foreach($task in $groupTasks){
        $taskId=[int]$task.media_id
        $row=$rowById[$taskId]
        $taskTitle=Normalize-FsMediaIdentityTitle ([string]$row.request_title)
        $taskPage=[long]$row.page_id
        $ok=($taskTitle -and $seenTitles.ContainsKey($taskTitle)) -or ($taskPage -gt 0 -and $seenPageIds.ContainsKey([string]$taskPage))
        if($ok){
            $statements.Add("UPDATE metadata_tasks SET status='done',lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE project_id=$ProjectId AND media_id=$taskId AND status='running' AND lease_owner=$workerSql;")
        }else{
            # The API request itself succeeded, so absence of imageinfo is a
            # completed negative check rather than an infrastructure failure.
            # Persist the checked level to prevent endless re-queuing on every
            # future Resume run.
            $statements.Add("UPDATE media SET metadata_checked_level=MAX(COALESCE(metadata_checked_level,0),$([int]$Config.Metadata.Level)),updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE id=$taskId;")
            $statements.Add("UPDATE metadata_tasks SET status='skipped',lease_owner=NULL,lease_until=NULL,last_error='Commons lieferte keine Bildmetadaten',updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE project_id=$ProjectId AND media_id=$taskId AND status='running' AND lease_owner=$workerSql;")
        }
    }
    Invoke-FsSqlBatch -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Statements $statements.ToArray() -Immediate -BatchSize 20 -Heartbeat $Heartbeat
}

function Invoke-FsMetadataWorkerItem {
    param([int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath,[hashtable]$Headers)
    $leaseSeconds=Get-FsWorkerLeaseSeconds -Stage 'metadata' -Config $Config
    $tasks=@(Claim-FsTask -Table 'metadata_tasks' -KeyColumn 'media_id' -ProjectId $ProjectId -Worker $Worker -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LeaseSeconds $leaseSeconds -Limit ([int]$Config.Metadata.BatchSize) -MaxAttempts (Get-FsTaskMaxAttempts -Config $Config) -RunId $RunId)
    if($tasks.Count -eq 0){return $false}
    $heartbeat=New-FsWorkerHeartbeat -ProjectId $ProjectId -RunId $RunId -Stage 'metadata' -Worker $Worker -LeaseSeconds $leaseSeconds -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MinimumSeconds $(if($Config.ContainsKey('Keyword') -and $Config.Keyword.ContainsKey('HeartbeatSeconds')){[int]$Config.Keyword.HeartbeatSeconds}else{60})
    $ids=@($tasks.media_id|ForEach-Object{[int]$_})
    $idList=$ids -join ','
    $mediaRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT id,page_id,title,COALESCE(NULLIF(canonical_title,''),title) request_title FROM media WHERE id IN ($idList);")
    $maxEncodedTitleChars=if($Config.Metadata.ContainsKey('MaxEncodedTitleChars')){[int]$Config.Metadata.MaxEncodedTitleChars}else{3500}
    $plan=Get-FsMetadataRequestGroups -Tasks $tasks -MediaRows $mediaRows -MaxTitles ([Math]::Min(50,[int]$Config.Metadata.BatchSize)) -MaxEncodedTitleChars $maxEncodedTitleChars

    if(@($plan.MissingTaskIds).Count -gt 0){
        $missingTasks=@($tasks|Where-Object{[int]$_.media_id -in @($plan.MissingTaskIds|ForEach-Object{[int]$_})})
        Set-FsMetadataBatchFailure -Tasks $missingTasks -ProjectId $ProjectId -Worker $Worker -Message 'Medium oder Commons-Titel fehlt' -SqlitePath $SqlitePath -DatabasePath $DatabasePath
    }
    foreach($group in @($plan.Groups)){
        Invoke-FsMetadataRequestGroup -Group $group -ProjectId $ProjectId -RunId $RunId -Worker $Worker -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Headers $Headers -Heartbeat $heartbeat
    }
    return $true
}

function Get-FsSeriesPrefix {
    param([string]$Title)
    $name=$Title -replace '^(?i)File:','';$dot=$name.LastIndexOf('.');if($dot -gt 0){$name=$name.Substring(0,$dot)}
    if($name -match '^(.*?[_\- ])\d{3,}$'){return $matches[1]};if($name -match '^(.*?\D)\d{4,}$'){return $matches[1]};return $null
}

function Invoke-FsNeighborResultBulkWrite {
    param(
        [int]$ProjectId,
        [object[]]$Items,
        [string]$SeedTitle,
        [int]$ParentMediaId,
        [string]$Uploader,
        [int]$Score=38,
        [string]$SqlitePath,
        [string]$DatabasePath,
        [scriptblock]$Heartbeat,
        [ValidateRange(1,250)][int]$ChunkSize=10
    )

    $rawCount=@($Items).Count
    $rows=New-Object Collections.ArrayList
    $seen=@{}
    foreach($image in @($Items)){
        $record=Convert-FsAllImageRecord $image
        $title=Normalize-FsFileTitle ([string](Get-FsPropertyValue -Object $record -Name 'Title'))
        if([string]::IsNullOrWhiteSpace($title) -or $title -eq (Normalize-FsFileTitle $SeedTitle)){continue}
        $normalized=Normalize-FsMediaIdentityTitle $title
        $sha1=Normalize-FsMediaIdentitySha1 ([string](Get-FsPropertyValue -Object $record -Name 'Sha1'))
        $key=if($sha1){'sha1:'+$sha1}else{'title:'+$normalized}
        if([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)){continue}
        $seen[$key]=$true
        [void]$rows.Add([pscustomobject]@{
            Title=$title
            NormalizedTitle=$normalized
            Sha1=$sha1
            Url=[string](Get-FsPropertyValue -Object $record -Name 'Url')
            DescriptionUrl=[string](Get-FsPropertyValue -Object $record -Name 'DescriptionUrl')
            Mime=[string](Get-FsPropertyValue -Object $record -Name 'Mime')
            MediaType=[string](Get-FsPropertyValue -Object $record -Name 'MediaType')
            Size=[long](Get-FsPropertyValue -Object $record -Name 'Size' -Default 0)
            Width=[int](Get-FsPropertyValue -Object $record -Name 'Width' -Default 0)
            Height=[int](Get-FsPropertyValue -Object $record -Name 'Height' -Default 0)
            CurrentUploader=[string](Get-FsPropertyValue -Object $record -Name 'CurrentUploader')
            CurrentTimestamp=[string](Get-FsPropertyValue -Object $record -Name 'CurrentTimestamp')
            MetadataJson=[string](Get-FsPropertyValue -Object $record -Name 'MetadataJson')
        })
    }

    if($rows.Count -eq 0){
        return [pscustomobject]@{InputCount=$rawCount;UniqueCount=0;Resolved=0;NewProjectMedia=0;Chunks=0;Seconds=0}
    }

    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    $seedSql=ConvertTo-FsSqlLiteral $SeedTitle
    $sourceSql=ConvertTo-FsSqlLiteral 'neighbor'
    $detailsSql=ConvertTo-FsSqlLiteral (@{uploader=$Uploader}|ConvertTo-Json -Compress)
    $offset=0
    $effectiveChunk=[Math]::Min($ChunkSize,$rows.Count)
    $chunks=0
    $resolvedTotal=0
    $newProjectTotal=0
    $watch=[Diagnostics.Stopwatch]::StartNew()

    while($offset -lt $rows.Count){
        $take=[Math]::Min($effectiveChunk,$rows.Count-$offset)
        $chunk=@($rows|Select-Object -Skip $offset -First $take)
        $values=New-Object Collections.Generic.List[string]
        $seq=0
        foreach($row in $chunk){
            $seq++
            $parts=@(
                [string]$seq,
                (ConvertTo-FsSqlLiteral ([string]$row.Title)),
                (ConvertTo-FsSqlLiteral ([string]$row.NormalizedTitle)),
                (ConvertTo-FsSqlLiteral ([string]$row.Sha1)),
                (ConvertTo-FsSqlLiteral ([string]$row.Url)),
                (ConvertTo-FsSqlLiteral ([string]$row.DescriptionUrl)),
                (ConvertTo-FsSqlLiteral ([string]$row.Mime)),
                (ConvertTo-FsSqlLiteral ([string]$row.MediaType)),
                (ConvertTo-FsSqlLiteral ([long]$row.Size)),
                (ConvertTo-FsSqlLiteral ([int]$row.Width)),
                (ConvertTo-FsSqlLiteral ([int]$row.Height)),
                (ConvertTo-FsSqlLiteral ([string]$row.CurrentUploader)),
                (ConvertTo-FsSqlLiteral ([string]$row.CurrentTimestamp)),
                (ConvertTo-FsSqlLiteral ([string]$row.MetadataJson))
            )
            $values.Add('('+($parts -join ',')+')')
        }

        $sql=@"
PRAGMA temp_store=MEMORY;
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_neighbor_input;
DROP TABLE IF EXISTS temp.fs_neighbor_canonical;
DROP TABLE IF EXISTS temp.fs_neighbor_existing_project;
CREATE TEMP TABLE fs_neighbor_input(
 seq INTEGER PRIMARY KEY,
 title TEXT NOT NULL COLLATE NOCASE,
 normalized_title TEXT COLLATE NOCASE,
 sha1 TEXT COLLATE NOCASE,
 url TEXT,
 description_url TEXT,
 mime TEXT,
 media_type TEXT,
 size INTEGER,
 width INTEGER,
 height INTEGER,
 current_uploader TEXT,
 current_timestamp TEXT,
 metadata_json TEXT,
 sha1_media_id INTEGER,
 title_media_id INTEGER,
 media_id INTEGER
);
INSERT INTO fs_neighbor_input(seq,title,normalized_title,sha1,url,description_url,mime,media_type,size,width,height,current_uploader,current_timestamp,metadata_json)
VALUES
$($values -join ",`n");

-- Resolve SHA-1 and title identities on separate indexed paths. Do not use an
-- OR predicate across the growing media table.
UPDATE fs_neighbor_input
SET sha1_media_id=(
 SELECT mi.media_id FROM media_identities mi
 WHERE mi.identity_type='sha1' AND mi.identity_value=fs_neighbor_input.sha1 COLLATE NOCASE
 LIMIT 1
)
WHERE sha1 IS NOT NULL AND sha1<>'';
UPDATE fs_neighbor_input
SET sha1_media_id=(
 SELECT m.id FROM media m WHERE m.sha1=fs_neighbor_input.sha1 COLLATE NOCASE LIMIT 1
)
WHERE sha1_media_id IS NULL AND sha1 IS NOT NULL AND sha1<>'';
UPDATE fs_neighbor_input
SET title_media_id=(
 SELECT mi.media_id FROM media_identities mi
 WHERE mi.identity_type='title' AND mi.identity_value=fs_neighbor_input.normalized_title COLLATE NOCASE
 LIMIT 1
)
WHERE normalized_title IS NOT NULL AND normalized_title<>'';
UPDATE fs_neighbor_input
SET title_media_id=COALESCE(
 (SELECT m.id FROM media m WHERE m.normalized_title=fs_neighbor_input.normalized_title COLLATE NOCASE LIMIT 1),
 (SELECT m.id FROM media m WHERE m.title=fs_neighbor_input.title COLLATE NOCASE LIMIT 1)
)
WHERE title_media_id IS NULL;
UPDATE fs_neighbor_input SET media_id=COALESCE(sha1_media_id,title_media_id);

INSERT OR IGNORE INTO media(
 page_id,title,normalized_title,canonical_title,sha1,url,description_url,mime,media_type,
 size,width,height,current_uploader,current_timestamp,metadata_json,
 metadata_level,metadata_checked_level,created_at,updated_at
)
SELECT NULL,title,normalized_title,title,sha1,url,description_url,mime,media_type,
       size,width,height,current_uploader,current_timestamp,metadata_json,
       0,0,$nowSql,$nowSql
FROM fs_neighbor_input
WHERE media_id IS NULL;

-- Resolve again after INSERT OR IGNORE. This also covers a concurrent/existing
-- UNIQUE title or SHA-1 row without retrying the expensive generic record SQL.
UPDATE fs_neighbor_input
SET sha1_media_id=COALESCE(sha1_media_id,
 (SELECT mi.media_id FROM media_identities mi WHERE mi.identity_type='sha1' AND mi.identity_value=fs_neighbor_input.sha1 COLLATE NOCASE LIMIT 1),
 (SELECT m.id FROM media m WHERE m.sha1=fs_neighbor_input.sha1 COLLATE NOCASE LIMIT 1)
)
WHERE sha1 IS NOT NULL AND sha1<>'';
UPDATE fs_neighbor_input
SET title_media_id=COALESCE(title_media_id,
 (SELECT mi.media_id FROM media_identities mi WHERE mi.identity_type='title' AND mi.identity_value=fs_neighbor_input.normalized_title COLLATE NOCASE LIMIT 1),
 (SELECT m.id FROM media m WHERE m.normalized_title=fs_neighbor_input.normalized_title COLLATE NOCASE LIMIT 1),
 (SELECT m.id FROM media m WHERE m.title=fs_neighbor_input.title COLLATE NOCASE LIMIT 1)
);
UPDATE fs_neighbor_input SET media_id=COALESCE(sha1_media_id,title_media_id);
CREATE INDEX fs_neighbor_input_media ON fs_neighbor_input(media_id);

INSERT OR IGNORE INTO media_identity_conflicts(media_id_a,media_id_b,reason,created_at)
SELECT MIN(sha1_media_id,title_media_id),MAX(sha1_media_id,title_media_id),'neighbor-sha1-title',$nowSql
FROM fs_neighbor_input
WHERE sha1_media_id IS NOT NULL AND title_media_id IS NOT NULL AND sha1_media_id<>title_media_id;

CREATE TEMP TABLE fs_neighbor_canonical AS
SELECT i.*
FROM fs_neighbor_input i
JOIN (
 SELECT media_id,MIN(seq) seq
 FROM fs_neighbor_input
 WHERE media_id IS NOT NULL
 GROUP BY media_id
) x ON x.seq=i.seq;
CREATE UNIQUE INDEX fs_neighbor_canonical_media ON fs_neighbor_canonical(media_id);

UPDATE media
SET normalized_title=COALESCE(NULLIF(media.normalized_title,''),c.normalized_title),
    canonical_title=COALESCE(NULLIF(media.canonical_title,''),c.title),
    sha1=CASE
       WHEN c.sha1 IS NOT NULL AND c.sha1<>''
        AND (media.sha1 IS NULL OR media.sha1='')
        AND NOT EXISTS(SELECT 1 FROM media x WHERE x.sha1=c.sha1 COLLATE NOCASE AND x.id<>media.id)
       THEN c.sha1 ELSE media.sha1 END,
    url=COALESCE(NULLIF(c.url,''),media.url),
    description_url=COALESCE(NULLIF(c.description_url,''),media.description_url),
    mime=COALESCE(NULLIF(c.mime,''),media.mime),
    media_type=COALESCE(NULLIF(c.media_type,''),media.media_type),
    size=CASE WHEN COALESCE(media.size,0)<=0 AND COALESCE(c.size,0)>0 THEN c.size ELSE media.size END,
    width=CASE WHEN COALESCE(media.width,0)<=0 AND COALESCE(c.width,0)>0 THEN c.width ELSE media.width END,
    height=CASE WHEN COALESCE(media.height,0)<=0 AND COALESCE(c.height,0)>0 THEN c.height ELSE media.height END,
    current_uploader=COALESCE(NULLIF(c.current_uploader,''),media.current_uploader),
    current_timestamp=COALESCE(NULLIF(c.current_timestamp,''),media.current_timestamp),
    metadata_json=COALESCE(media.metadata_json,NULLIF(c.metadata_json,'')),
    updated_at=$nowSql
FROM fs_neighbor_canonical c
WHERE media.id=c.media_id;

INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'sha1',sha1,media_id,'neighbor',$nowSql,$nowSql
FROM fs_neighbor_canonical WHERE sha1 IS NOT NULL AND sha1<>'';
INSERT OR IGNORE INTO media_identities(identity_type,identity_value,media_id,source,created_at,updated_at)
SELECT 'title',normalized_title,media_id,'neighbor',$nowSql,$nowSql
FROM fs_neighbor_canonical WHERE normalized_title IS NOT NULL AND normalized_title<>'';

CREATE TEMP TABLE fs_neighbor_existing_project AS
SELECT c.media_id
FROM fs_neighbor_canonical c
JOIN project_media pm ON pm.project_id=$ProjectId AND pm.media_id=c.media_id;
CREATE UNIQUE INDEX fs_neighbor_existing_project_media ON fs_neighbor_existing_project(media_id);

INSERT INTO project_media(project_id,media_id,score,best_source,selected,first_seen_at,updated_at)
SELECT $ProjectId,m.id,$Score,$sourceSql,1,$nowSql,$nowSql
FROM fs_neighbor_canonical c
JOIN media m ON m.id=c.media_id
WHERE NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.media_id=m.id)
  AND (m.page_id IS NULL OR m.page_id<=0 OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.page_id=m.page_id))
  AND (m.sha1 IS NULL OR m.sha1='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.sha1=m.sha1 COLLATE NOCASE))
  AND (m.normalized_title IS NULL OR m.normalized_title='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.normalized_title=m.normalized_title COLLATE NOCASE))
ON CONFLICT(project_id,media_id) DO UPDATE SET
 score=MAX(project_media.score,excluded.score),
 best_source=CASE WHEN excluded.score>project_media.score OR project_media.best_source IS NULL THEN excluded.best_source ELSE project_media.best_source END,
 updated_at=excluded.updated_at
WHERE excluded.score>project_media.score OR project_media.best_source IS NULL;

INSERT OR IGNORE INTO discoveries(
 project_id,media_id,source_type,source_value,score,language,query_text,
 origin_category_id,parent_media_id,details_json,created_at
)
SELECT $ProjectId,m.id,$sourceSql,$seedSql,$Score,NULL,NULL,NULL,$ParentMediaId,$detailsSql,$nowSql
FROM fs_neighbor_canonical c
JOIN media m ON m.id=c.media_id
WHERE NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.media_id=m.id)
  AND (m.page_id IS NULL OR m.page_id<=0 OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.page_id=m.page_id))
  AND (m.sha1 IS NULL OR m.sha1='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.sha1=m.sha1 COLLATE NOCASE))
  AND (m.normalized_title IS NULL OR m.normalized_title='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.normalized_title=m.normalized_title COLLATE NOCASE));

COMMIT;
SELECT
 (SELECT COUNT(*) FROM fs_neighbor_input) input_count,
 (SELECT COUNT(*) FROM fs_neighbor_canonical) resolved_count,
 (SELECT COUNT(*) FROM fs_neighbor_canonical)-(SELECT COUNT(*) FROM fs_neighbor_existing_project) new_project_media;
DROP TABLE IF EXISTS temp.fs_neighbor_existing_project;
DROP TABLE IF EXISTS temp.fs_neighbor_canonical;
DROP TABLE IF EXISTS temp.fs_neighbor_input;
"@

        try{
            if($null -ne $Heartbeat){& $Heartbeat}
            [object[]]$summary=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql $sql -ExecutionTimeoutMs 30000 -WriteLockTimeoutMs 60000 -BusyRetries 0 -ProgressLabel ("Neighbor-Ergebnisse schreiben | {0}-{1}/{2}; Chunk {3}" -f ($offset+1),($offset+$take),$rows.Count,$take))
            if($summary.Count -eq 0){throw 'Neighbor-Bulk lieferte keine Schreibstatistik.'}
            $resolvedTotal+=[int]$summary[0].resolved_count
            $newProjectTotal+=[int]$summary[0].new_project_media
            $offset+=$take
            $chunks++
        }
        catch{
            if($_.Exception.Message -match 'SQLite-Ausführungszeit' -and $take -gt 1){
                $effectiveChunk=[Math]::Max(1,[int][Math]::Floor($take/2.0))
                Write-Host ("        [NEIGHBOR-BULK] SQL-Chunk war zu groß; reduziere auf {0} Treffer und setze bei {1}/{2} fort." -f $effectiveChunk,$offset,$rows.Count) -ForegroundColor DarkYellow
                continue
            }
            throw
        }
    }

    return [pscustomobject]@{
        InputCount=$rawCount
        UniqueCount=$rows.Count
        Resolved=$resolvedTotal
        NewProjectMedia=$newProjectTotal
        Chunks=$chunks
        Seconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
    }
}


function Invoke-FsNeighborWorkerItem {
    param([int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath,[hashtable]$Headers)
    $leaseSeconds=Get-FsWorkerLeaseSeconds -Stage 'neighbor' -Config $Config
    $task=@(Claim-FsTask -Table 'neighbor_tasks' -KeyColumn 'media_id' -ProjectId $ProjectId -Worker $Worker -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LeaseSeconds $leaseSeconds -Limit 1 -MaxAttempts (Get-FsTaskMaxAttempts -Config $Config) -RunId $RunId)
    if($task.Count -eq 0){return $false}
    $t=$task[0]
    $heartbeat=New-FsWorkerHeartbeat -ProjectId $ProjectId -RunId $RunId -Stage 'neighbor' -Worker $Worker -LeaseSeconds $leaseSeconds -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MinimumSeconds $(if($Config.ContainsKey('Keyword') -and $Config.Keyword.ContainsKey('HeartbeatSeconds')){[int]$Config.Keyword.HeartbeatSeconds}else{60})
    [object[]]$neighborRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT * FROM media WHERE id=$([int]$t.media_id);")
    if($neighborRows.Length -eq 0){[void](Complete-FsTask -Table 'neighbor_tasks' -Where "project_id=$ProjectId AND media_id=$([int]$t.media_id)" -Status 'failed' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -Error 'Medium fehlt');return $true}
    $seed=$neighborRows[0];$clock=[Diagnostics.Stopwatch]::StartNew();$apiPages=0;$results=0;$scanned=0
    try {
        & $heartbeat
        $user=[string]$seed.current_uploader;$timestamp=$null;try{$timestamp=[DateTime]$seed.current_timestamp}catch{}
        if([string]::IsNullOrWhiteSpace($user) -or $null -eq $timestamp){[void](Complete-FsTask -Table 'neighbor_tasks' -Where "project_id=$ProjectId AND media_id=$([int]$t.media_id)" -Status 'skipped' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -Error 'Uploader oder Zeitstempel fehlt');return $true}
        $all=New-Object Collections.Generic.List[object];$continuation=$null
        do {
            if($apiPages -ge [int]$Config.Neighbors.MaxApiPagesPerSeed -or $clock.Elapsed.TotalSeconds -ge [int]$Config.Neighbors.MaxSecondsPerSeed){break}
            $apiPages++;$start=$timestamp.ToUniversalTime().AddMinutes(-[int]$Config.Neighbors.Minutes);$end=$timestamp.ToUniversalTime().AddMinutes([int]$Config.Neighbors.Minutes)
            $params=@{action='query';list='allimages';aisort='timestamp';aidir='newer';aistart=$start.ToString('yyyy-MM-ddTHH:mm:ssZ');aiend=$end.ToString('yyyy-MM-ddTHH:mm:ssZ');aiuser=$user;ailimit=[Math]::Min(500,[int]$Config.Neighbors.MaxResultsPerSeed);aiprop='timestamp|user|url|size|sha1|mime|mediatype'}
            if($continuation){foreach($cp in $continuation.PSObject.Properties){$params[$cp.Name]=$cp.Value}}
            $response=Invoke-FsCommonsApi -Parameters $params -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs ([int]$Config.Api.DelayMs) -Retries ([int]$Config.Api.Retries) -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage 'neighbor' -Heartbeat $heartbeat
            $neighborQuery=Get-FsPropertyValue -Object $response -Name 'query'
            $neighborImages=Get-FsPropertyValue -Object $neighborQuery -Name 'allimages' -Default @()
            foreach($image in @($neighborImages)){$all.Add($image);if($all.Count -ge [int]$Config.Neighbors.MaxResultsPerSeed){break}}
            $continueNode=Get-FsPropertyValue -Object $response -Name 'continue'
            $continuation=if($null -ne $continueNode -and $all.Count -lt [int]$Config.Neighbors.MaxResultsPerSeed){$continueNode}else{$null}
        }while($continuation)
        if([bool]$Config.Neighbors.SeriesExpansion -and $all.Count -lt [int]$Config.Neighbors.MaxResultsPerSeed -and $clock.Elapsed.TotalSeconds -lt [int]$Config.Neighbors.MaxSecondsPerSeed){
            $prefix=Get-FsSeriesPrefix ([string]$(if($seed.canonical_title){$seed.canonical_title}else{$seed.title}));$cont=$null
            if($prefix){
                do {
                    if($apiPages -ge [int]$Config.Neighbors.MaxApiPagesPerSeed){break}
                    $apiPages++;$params=@{action='query';list='allimages';aisort='name';aiprefix=$prefix;ailimit=500;aiprop='timestamp|user|url|size|sha1|mime|mediatype'}
                    if($cont){foreach($cp in $cont.PSObject.Properties){$params[$cp.Name]=$cp.Value}}
                    $response=Invoke-FsCommonsApi -Parameters $params -SqlitePath $SqlitePath -DatabasePath $DatabasePath -DelayMs ([int]$Config.Api.DelayMs) -Retries ([int]$Config.Api.Retries) -Headers $Headers -ProjectId $ProjectId -RunId $RunId -Stage 'neighbor' -Heartbeat $heartbeat
                    $seriesQuery=Get-FsPropertyValue -Object $response -Name 'query'
                    $seriesImages=Get-FsPropertyValue -Object $seriesQuery -Name 'allimages' -Default @()
                    foreach($image in @($seriesImages)){$scanned++;if([string](Get-FsPropertyValue -Object $image -Name 'user') -eq $user){$all.Add($image);if($all.Count -ge [int]$Config.Neighbors.MaxResultsPerSeed){break}};if($scanned -ge [int]$Config.Neighbors.MaxUploaderScan){break}}
                    $seriesContinue=Get-FsPropertyValue -Object $response -Name 'continue'
                    $cont=if($null -ne $seriesContinue -and $all.Count -lt [int]$Config.Neighbors.MaxResultsPerSeed -and $scanned -lt [int]$Config.Neighbors.MaxUploaderScan){$seriesContinue}else{$null}
                }while($cont -and $clock.Elapsed.TotalSeconds -lt [int]$Config.Neighbors.MaxSecondsPerSeed)
            }
        }
        $neighborWrite=Invoke-FsNeighborResultBulkWrite -ProjectId $ProjectId -Items ([object[]]$all.ToArray()) -SeedTitle ([string]$seed.title) -ParentMediaId ([int]$seed.id) -Uploader $user -Score 38 -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Heartbeat $heartbeat -ChunkSize 10
        $results=[int]$neighborWrite.UniqueCount
        [void](Complete-FsTask -Table 'neighbor_tasks' -Where "project_id=$ProjectId AND media_id=$([int]$t.media_id)" -Status 'done' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -Additional @{api_pages=$apiPages;results_count=$results})
        return $true
    } catch {if(Test-FsInfrastructureTaskError -Message $_.Exception.Message){throw};[void](Complete-FsTask -Table 'neighbor_tasks' -Where "project_id=$ProjectId AND media_id=$([int]$t.media_id)" -Status 'failed' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Worker $Worker -Error $_.Exception.Message -Additional @{api_pages=$apiPages;results_count=$results});return $true}
}


function Test-FsDownloadAutoTuneEnabled {
    param([hashtable]$Config)
    return ($null -ne $Config -and $Config.ContainsKey('Download') -and $Config.Download.ContainsKey('AutoTune') -and [bool]$Config.Download.AutoTune)
}

function Open-FsDownloadTuneLock {
    param([Parameter(Mandatory=$true)][string]$DatabasePath,[int]$WaitSeconds=10)
    $lockPath=$DatabasePath+'.download-tuning.lock'
    $deadline=[DateTime]::UtcNow.AddSeconds([Math]::Max(1,$WaitSeconds))
    do{
        try{return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException]{Start-Sleep -Milliseconds 20}
    }while([DateTime]::UtcNow -lt $deadline)
    return $null
}

function Initialize-FsDownloadAutoTune {
    param(
        [int]$ProjectId,[int]$RunId,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath
    )
    Ensure-FsDownloadTuningSchema -SqlitePath $SqlitePath -DatabasePath $DatabasePath
    $enabled=if(Test-FsDownloadAutoTuneEnabled -Config $Config){1}else{0}
    $configuredDelay=if($Config.Download.ContainsKey('DelayMs')){[Math]::Max(0,[int]$Config.Download.DelayMs)}else{0}
    $baselineRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT
 COALESCE(SUM(CASE WHEN status='done' THEN 1 ELSE 0 END),0) done_count,
 COALESCE(SUM(CASE WHEN status='reused' THEN 1 ELSE 0 END),0) reused_count,
 COALESCE(SUM(CASE WHEN status IN ('done','reused','failed','skipped') THEN 1 ELSE 0 END),0) terminal_count
FROM project_downloads WHERE project_id=$ProjectId;
"@ -ExecutionTimeoutMs 10000)
    $baselineDone=if($baselineRows.Count){[int]$baselineRows[0].done_count}else{0}
    $baselineReused=if($baselineRows.Count){[int]$baselineRows[0].reused_count}else{0}
    $baselineTerminal=if($baselineRows.Count){[int]$baselineRows[0].terminal_count}else{0}
    $runStartedAtMs=Get-FsUnixMilliseconds

    # HF50: Charts and counters are per run, but a very recent 429 safety state
    # survives a restart. Otherwise every hotfix restart would immediately retry
    # at 400 ms while Wikimedia may still be throttling the same client.
    $previousRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT current_delay_ms,burst_open,cooldown_until_ms,last_429_at_ms,last_429_at FROM download_tuning WHERE project_id=$ProjectId LIMIT 1;" -ExecutionTimeoutMs 5000)
    $carryoverSeconds=if($Config.Download.ContainsKey('ThrottleCarryoverSeconds')){[Math]::Max(0,[int]$Config.Download.ThrottleCarryoverSeconds)}else{900}
    $pauseSeconds=if($Config.Download.ContainsKey('ThrottlePauseSeconds')){[Math]::Max(1,[int]$Config.Download.ThrottlePauseSeconds)}else{20}
    $startDelay=$configuredDelay
    $carryBurstOpen=0
    $carryCooldownUntilMs=[long]0
    $carryLast429AtMs=[long]0
    $carryLast429At=$null
    if($previousRows.Count -gt 0){
        $previous=$previousRows[0]
        $previousLast429=if($null -eq $previous.last_429_at_ms){[long]0}else{[long]$previous.last_429_at_ms}
        $previousCooldown=if($null -eq $previous.cooldown_until_ms){[long]0}else{[long]$previous.cooldown_until_ms}
        $recent429=($previousLast429 -gt 0 -and $carryoverSeconds -gt 0 -and ($runStartedAtMs-$previousLast429) -le ([long]$carryoverSeconds*1000))
        if($previousCooldown -gt $runStartedAtMs -or $recent429){
            $startDelay=[Math]::Max($configuredDelay,[Math]::Max(0,[int]$previous.current_delay_ms))
            $carryBurstOpen=1
            $carryLast429AtMs=$previousLast429
            $carryLast429At=[string]$previous.last_429_at
            $carryCooldownUntilMs=[Math]::Max($previousCooldown,$runStartedAtMs+([long]$pauseSeconds*1000))
        }
    }
    $reason=if($carryBurstOpen -eq 1){
        "Sicherheitszustand aus dem vorherigen Lauf übernommen: Start bei $startDelay ms und ${pauseSeconds}s gemeinsame Pause; Messreihen beginnen dennoch leer."
    }else{
        "Sicherer Neustart bei $startDelay ms; keine aktuelle 429-Schutzlage übernommen."
    }
    $last429AtSql=if([string]::IsNullOrWhiteSpace($carryLast429At)){'NULL'}else{ConvertTo-FsSqlLiteral $carryLast429At}
    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
INSERT INTO download_tuning(
 project_id,run_id,enabled,current_delay_ms,direction,step_ms,window_target,
 window_successes,window_bytes,window_started_at_ms,
 previous_files_per_second,previous_bytes_per_second,
 last_window_delay_ms,last_window_successes,last_window_elapsed_ms,
 last_window_files_per_second,last_window_bytes_per_second,last_window_at,last_decision_at,
 best_delay_ms,best_files_per_second,best_bytes_per_second,
 hold_windows,throttle_bursts,burst_open,cooldown_until_ms,last_stable_delay_ms,
 total_429,last_429_at_ms,last_429_at,last_change_reason,
 run_start_terminal,run_start_done,run_start_reused,run_started_at_ms,updated_at
)
VALUES(
 $ProjectId,$RunId,$enabled,$startDelay,-1,20,100,
 0,0,0,
 NULL,NULL,
 NULL,0,0,NULL,NULL,NULL,NULL,
 NULL,NULL,NULL,
 0,0,$carryBurstOpen,$carryCooldownUntilMs,NULL,
 0,$carryLast429AtMs,$last429AtSql,$(ConvertTo-FsSqlLiteral $reason),
 $baselineTerminal,$baselineDone,$baselineReused,$runStartedAtMs,$nowSql
)
ON CONFLICT(project_id) DO UPDATE SET
 run_id=excluded.run_id,
 enabled=excluded.enabled,
 current_delay_ms=excluded.current_delay_ms,
 direction=-1,
 step_ms=20,
 window_target=100,
 window_successes=0,
 window_bytes=0,
 window_started_at_ms=0,
 previous_files_per_second=NULL,
 previous_bytes_per_second=NULL,
 last_window_delay_ms=NULL,
 last_window_successes=0,
 last_window_elapsed_ms=0,
 last_window_files_per_second=NULL,
 last_window_bytes_per_second=NULL,
 last_window_at=NULL,
 last_decision_at=NULL,
 best_delay_ms=NULL,
 best_files_per_second=NULL,
 best_bytes_per_second=NULL,
 hold_windows=0,
 throttle_bursts=0,
 burst_open=excluded.burst_open,
 cooldown_until_ms=excluded.cooldown_until_ms,
 last_stable_delay_ms=NULL,
 total_429=0,
 last_429_at_ms=excluded.last_429_at_ms,
 last_429_at=excluded.last_429_at,
 last_change_reason=excluded.last_change_reason,
 run_start_terminal=excluded.run_start_terminal,
 run_start_done=excluded.run_start_done,
 run_start_reused=excluded.run_start_reused,
 run_started_at_ms=excluded.run_started_at_ms,
 updated_at=excluded.updated_at;
UPDATE api_gate SET adaptive_delay_ms=0 WHERE name='commons-download';
"@ | Out-Null
    if($carryCooldownUntilMs -gt $runStartedAtMs){
        $remaining=[Math]::Max(1,[int][Math]::Ceiling(($carryCooldownUntilMs-(Get-FsUnixMilliseconds))/1000.0))
        $startupRecoverySlots=if($Config.Download.ContainsKey('Workers')){[Math]::Max(1,[Math]::Min(64,[int]$Config.Download.Workers))}else{4}
        $startupRecoverySpacingMs=if($Config.Download.ContainsKey('RecoveryWorkerSpacingMs')){[Math]::Max(0,[int]$Config.Download.RecoveryWorkerSpacingMs)}else{3000}
        [void](Set-FsDownloadApiCooldown -DatabasePath $DatabasePath -Seconds $remaining -RecoverySlots $startupRecoverySlots -RecoverySpacingMs $startupRecoverySpacingMs)
    }
    return Get-FsDownloadAutoTuneStatus -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $DatabasePath
}

function Get-FsDownloadAutoTuneDelay {
    param([int]$ProjectId,[hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath)
    $configured=if($Config.Download.ContainsKey('DelayMs')){[Math]::Max(0,[int]$Config.Download.DelayMs)}else{0}
    if(-not(Test-FsDownloadAutoTuneEnabled -Config $Config)){return $configured}

    # HF50: Each worker caches the shared delay briefly. The controller changes
    # it only after a complete 100-file window or a 429 burst; querying SQLite
    # before every file only creates process/reader overhead.
    if($null -eq $script:FsDownloadDelayCache){$script:FsDownloadDelayCache=@{}}
    $cacheKey="$DatabasePath|$ProjectId"
    $cacheSeconds=if($Config.Download.ContainsKey('DelayCacheSeconds')){[Math]::Max(1,[int]$Config.Download.DelayCacheSeconds)}else{5}
    $cached=$null
    if($script:FsDownloadDelayCache.ContainsKey($cacheKey)){
        $cached=$script:FsDownloadDelayCache[$cacheKey]
        if(([DateTime]::UtcNow-$cached.At).TotalSeconds -lt $cacheSeconds){return [int]$cached.Delay}
    }
    # On a transient read error retain the last known shared value rather than
    # falling back to the configured start delay and creating an artificial jump.
    $delay=if($null -ne $cached){[int]$cached.Delay}else{$configured}
    try{
        $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT current_delay_ms FROM download_tuning WHERE project_id=$ProjectId AND enabled=1 LIMIT 1;" -ExecutionTimeoutMs 5000)
        if($rows.Count -gt 0){$delay=[Math]::Max(0,[int]$rows[0].current_delay_ms)}
    }catch{}
    $script:FsDownloadDelayCache[$cacheKey]=[pscustomobject]@{At=[DateTime]::UtcNow;Delay=$delay}
    return $delay
}

function Get-FsDownloadAutoTuneStatus {
    param([int]$ProjectId,[string]$SqlitePath,[string]$DatabasePath)
    $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT * FROM download_tuning WHERE project_id=$ProjectId LIMIT 1;" -ExecutionTimeoutMs 5000)
    if($rows.Count -eq 0){return $null}
    $row=$rows[0]
    $nowMs=Get-FsUnixMilliseconds
    $started=[long]$row.window_started_at_ms
    $elapsedMs=if($started -gt 0){[Math]::Max(1,$nowMs-$started)}else{0}
    $windowFilesPerSecond=if($elapsedMs -gt 0){[double]$row.window_successes/($elapsedMs/1000.0)}else{0.0}
    $windowBytesPerSecond=if($elapsedMs -gt 0){[double]$row.window_bytes/($elapsedMs/1000.0)}else{0.0}
    $direction=[int]$row.direction
    $lastWindowDelay=$(if($null -eq $row.last_window_delay_ms){$null}else{[int]$row.last_window_delay_ms})
    $lastWindowFiles=$(if($null -eq $row.last_window_files_per_second){$null}else{[double]$row.last_window_files_per_second})
    $lastWindowBytes=$(if($null -eq $row.last_window_bytes_per_second){$null}else{[double]$row.last_window_bytes_per_second})
    return [pscustomobject]@{
        Enabled=([int]$row.enabled -eq 1)
        RunId=[int]$row.run_id
        CurrentDelayMs=[int]$row.current_delay_ms
        Direction=$direction
        DirectionText=$(if($direction -lt 0){'runter'}elseif($direction -gt 0){'rauf'}else{'halten'})
        DirectionSymbol=$(if($direction -lt 0){'v'}elseif($direction -gt 0){'^'}else{'='})
        StepMs=[int]$row.step_ms
        WindowTarget=[int]$row.window_target
        WindowSuccesses=[int]$row.window_successes
        WindowBytes=[long]$row.window_bytes
        WindowElapsedMs=[long]$elapsedMs
        WindowFilesPerSecond=[double]$windowFilesPerSecond
        WindowBytesPerSecond=[double]$windowBytesPerSecond
        PreviousFilesPerSecond=$(if($null -eq $row.previous_files_per_second){$null}else{[double]$row.previous_files_per_second})
        PreviousBytesPerSecond=$(if($null -eq $row.previous_bytes_per_second){$null}else{[double]$row.previous_bytes_per_second})
        HasCompletedWindow=($null -ne $lastWindowDelay -and $null -ne $lastWindowFiles)
        LastWindowDelayMs=$lastWindowDelay
        LastWindowSuccesses=$(if($null -eq $row.last_window_successes){0}else{[int]$row.last_window_successes})
        LastWindowElapsedMs=$(if($null -eq $row.last_window_elapsed_ms){0}else{[long]$row.last_window_elapsed_ms})
        LastWindowFilesPerSecond=$lastWindowFiles
        LastWindowBytesPerSecond=$lastWindowBytes
        LastWindowAt=[string]$row.last_window_at
        LastDecisionAt=[string]$row.last_decision_at
        BestDelayMs=$(if($null -eq $row.best_delay_ms){$null}else{[int]$row.best_delay_ms})
        BestFilesPerSecond=$(if($null -eq $row.best_files_per_second){$null}else{[double]$row.best_files_per_second})
        BestBytesPerSecond=$(if($null -eq $row.best_bytes_per_second){$null}else{[double]$row.best_bytes_per_second})
        HoldWindows=[int]$row.hold_windows
        ThrottleBursts=$(if($null -eq $row.throttle_bursts){0}else{[int]$row.throttle_bursts})
        BurstOpen=$(if($null -eq $row.burst_open){$false}else{[int]$row.burst_open -eq 1})
        CooldownUntilMs=$(if($null -eq $row.cooldown_until_ms){0}else{[long]$row.cooldown_until_ms})
        LastStableDelayMs=$(if($null -eq $row.last_stable_delay_ms){$null}else{[int]$row.last_stable_delay_ms})
        Total429=[int]$row.total_429
        Last429AtMs=$(if($null -eq $row.last_429_at_ms){0}else{[long]$row.last_429_at_ms})
        Last429At=[string]$row.last_429_at
        LastChangeReason=[string]$row.last_change_reason
        RunStartTerminal=$(if($null -eq $row.run_start_terminal){0}else{[int]$row.run_start_terminal})
        RunStartDone=$(if($null -eq $row.run_start_done){0}else{[int]$row.run_start_done})
        RunStartReused=$(if($null -eq $row.run_start_reused){0}else{[int]$row.run_start_reused})
        RunStartedAtMs=$(if($null -eq $row.run_started_at_ms){0}else{[long]$row.run_started_at_ms})
        UpdatedAt=[string]$row.updated_at
    }
}

function Get-FsDownloadDoneBytes {
    param([int]$ProjectId,[string]$SqlitePath,[string]$DatabasePath)
    $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT COALESCE(SUM(CASE WHEN d.bytes IS NULL THEN 0 ELSE d.bytes END),0) total_bytes
FROM project_downloads pd
JOIN downloads d ON d.media_id=pd.media_id
WHERE pd.project_id=$ProjectId AND pd.status='done';
"@ -ExecutionTimeoutMs 15000)
    if($rows.Count -eq 0){return [long]0}
    return [long]$rows[0].total_bytes
}

# HF50 delay changes remain bounded to 20..100 ms.
function Get-FsDownloadDelayIncreaseAmount {
    param([int]$DelayMs,[hashtable]$Config)
    $percent=if($Config.Download.ContainsKey('DelayIncreasePercent')){[Math]::Max(1,[double]$Config.Download.DelayIncreasePercent)}else{25.0}
    $minimum=if($Config.Download.ContainsKey('DelayIncreaseMinMs')){[Math]::Max(1,[int]$Config.Download.DelayIncreaseMinMs)}else{20}
    $maximum=if($Config.Download.ContainsKey('DelayIncreaseMaxMs')){[Math]::Max($minimum,[int]$Config.Download.DelayIncreaseMaxMs)}else{100}
    $relative=[int][Math]::Ceiling([Math]::Max(0,$DelayMs)*$percent/100.0)
    return [Math]::Min($maximum,[Math]::Max($minimum,$relative))
}

function Get-FsDownloadDelayDecreaseAmount {
    param([int]$DelayMs,[hashtable]$Config)
    if($DelayMs -le 0){return 0}
    $percent=if($Config.Download.ContainsKey('DelayDecreasePercent')){[Math]::Max(1,[double]$Config.Download.DelayDecreasePercent)}else{10.0}
    $minimum=if($Config.Download.ContainsKey('DelayDecreaseMinMs')){[Math]::Max(1,[int]$Config.Download.DelayDecreaseMinMs)}else{20}
    $maximum=if($Config.Download.ContainsKey('DelayDecreaseMaxMs')){[Math]::Max($minimum,[int]$Config.Download.DelayDecreaseMaxMs)}else{100}
    $relative=[int][Math]::Ceiling($DelayMs*$percent/100.0)
    return [Math]::Min($maximum,[Math]::Max($minimum,$relative))
}

function Get-FsDownloadAutoTuneMinDelayMs {
    param([hashtable]$Config)
    $configured=if($Config.Download.ContainsKey('DelayMs')){[Math]::Max(0,[int]$Config.Download.DelayMs)}else{0}
    if($Config.Download.ContainsKey('AutoTuneMinDelayMs')){
        return [Math]::Min($configured,[Math]::Max(0,[int]$Config.Download.AutoTuneMinDelayMs))
    }
    # Safe production default: when starting at >=1 s never explore below 1 s
    # unless the caller explicitly opts into a lower floor. Small synthetic/test
    # delays retain their historical ability to tune down to zero.
    if($configured -ge 1000){return 1000}
    return 0
}

function Get-FsDownloadAutoTuneMinImprovementPct {
    param([hashtable]$Config)
    if($Config.Download.ContainsKey('AutoTuneMinImprovementPct')){
        return [Math]::Max(0.0,[double]$Config.Download.AutoTuneMinImprovementPct)
    }
    return 2.0
}

function Get-FsDownloadBurstRecoverySettings {
    param([hashtable]$Config)
    $successes=if($Config.Download.ContainsKey('BurstRecoverySuccesses')){[Math]::Max(1,[int]$Config.Download.BurstRecoverySuccesses)}else{8}
    $seconds=if($Config.Download.ContainsKey('BurstRecoverySeconds')){[Math]::Max(1,[int]$Config.Download.BurstRecoverySeconds)}else{20}
    return [pscustomobject]@{Successes=$successes;Seconds=$seconds}
}

function Update-FsDownloadAutoTuneProgress {
    param(
        [int]$ProjectId,[int]$RunId,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath,
        [int]$Successes,[long]$Bytes,[long]$ElapsedMs,[switch]$WriteLiveSample
    )
    if(-not(Test-FsDownloadAutoTuneEnabled -Config $Config)){return $null}
    $safeSuccesses=[Math]::Max(0,$Successes)
    $safeBytes=[Math]::Max([long]0,$Bytes)
    $safeElapsed=[Math]::Max([long]1,$ElapsedMs)
    $fps=[double]$safeSuccesses/($safeElapsed/1000.0)
    $bps=[double]$safeBytes/($safeElapsed/1000.0)
    $now=Get-FsUtcNowText
    $nowMs=Get-FsUnixMilliseconds
    $recovery=Get-FsDownloadBurstRecoverySettings -Config $Config
    $lock=Open-FsDownloadTuneLock -DatabasePath $DatabasePath
    if($null -eq $lock){throw 'Autotune-Sperre konnte nicht erworben werden.'}
    try{
        $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT * FROM download_tuning WHERE project_id=$ProjectId AND enabled=1 LIMIT 1;" -ExecutionTimeoutMs 5000)
        if($rows.Count -eq 0){return $null}
        $row=$rows[0]
        $current=[Math]::Max(0,[int]$row.current_delay_ms)
        $last429Ms=if($null -eq $row.last_429_at_ms){[long]0}else{[long]$row.last_429_at_ms}
        $burstOpen=($null -ne $row.burst_open -and [int]$row.burst_open -eq 1)
        $recoveryReady=($burstOpen -and $safeSuccesses -ge [int]$recovery.Successes -and $last429Ms -gt 0 -and ($nowMs-$last429Ms) -ge ([long]$recovery.Seconds*1000))
        if($recoveryReady){
            $floor=Get-FsDownloadAutoTuneMinDelayMs -Config $Config
            $decrease=Get-FsDownloadDelayDecreaseAmount -DelayMs $current -Config $Config
            $next=[Math]::Max($floor,$current-$decrease)
            $actualDecrease=[Math]::Max(0,$current-$next)
            $direction=if($next -lt $current){-1}else{0}
            $reason=if($next -lt $current){
                "429-Stabilisierung abgeschlossen: $safeSuccesses erfolgreiche Dateien und mindestens $([int]$recovery.Seconds)s ohne neue 429; Anfrageabstand $current -> $next ms (-$actualDecrease ms; Floor $floor ms)."
            }else{
                "429-Stabilisierung abgeschlossen: AutoTune-Floor $floor ms bleibt bestehen."
            }
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
INSERT INTO download_tuning_samples(project_id,run_id,sample_type,delay_ms,next_delay_ms,direction,successes,bytes,elapsed_ms,files_per_second,bytes_per_second,status_code,note,created_at)
VALUES($ProjectId,$RunId,'recovery',$current,$next,$direction,$safeSuccesses,$safeBytes,$safeElapsed,$(ConvertTo-FsSqlLiteral $fps),$(ConvertTo-FsSqlLiteral $bps),200,$(ConvertTo-FsSqlLiteral $reason),$(ConvertTo-FsSqlLiteral $now));
UPDATE download_tuning SET
 run_id=$RunId,
 current_delay_ms=$next,
 direction=$direction,
 window_successes=0,
 window_bytes=0,
 window_started_at_ms=0,
 previous_files_per_second=$(ConvertTo-FsSqlLiteral $fps),
 previous_bytes_per_second=$(ConvertTo-FsSqlLiteral $bps),
 last_window_delay_ms=$current,
 last_window_successes=$safeSuccesses,
 last_window_elapsed_ms=$safeElapsed,
 last_window_files_per_second=$(ConvertTo-FsSqlLiteral $fps),
 last_window_bytes_per_second=$(ConvertTo-FsSqlLiteral $bps),
 last_window_at=$(ConvertTo-FsSqlLiteral $now),
 last_decision_at=$(ConvertTo-FsSqlLiteral $now),
 hold_windows=0,
 burst_open=0,
 cooldown_until_ms=0,
 last_stable_delay_ms=$current,
 last_change_reason=$(ConvertTo-FsSqlLiteral $reason),
 updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND enabled=1;
COMMIT;
"@ -ExecutionTimeoutMs 15000 | Out-Null
        }else{
            $sampleSql=''
            if($WriteLiveSample){
                $sampleSql=@"
INSERT INTO download_tuning_samples(project_id,run_id,sample_type,delay_ms,next_delay_ms,direction,successes,bytes,elapsed_ms,files_per_second,bytes_per_second,status_code,note,created_at)
SELECT project_id,$RunId,'live',current_delay_ms,current_delay_ms,direction,$safeSuccesses,$safeBytes,$safeElapsed,$(ConvertTo-FsSqlLiteral $fps),$(ConvertTo-FsSqlLiteral $bps),200,'laufendes Messfenster',$(ConvertTo-FsSqlLiteral $now)
FROM download_tuning WHERE project_id=$ProjectId AND enabled=1;
"@
            }
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
$sampleSql
UPDATE download_tuning SET
 run_id=$RunId,
 window_successes=$safeSuccesses,
 window_bytes=$safeBytes,
 window_started_at_ms=$([Math]::Max([long]0,$nowMs-$safeElapsed)),
 updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND enabled=1;
COMMIT;
"@ -ExecutionTimeoutMs 15000 | Out-Null
        }
    }finally{$lock.Dispose()}
    return Get-FsDownloadAutoTuneStatus -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $DatabasePath
}

function Complete-FsDownloadAutoTuneWindow {
    param(
        [int]$ProjectId,[int]$RunId,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath,
        [int]$Successes,[long]$Bytes,[long]$ElapsedMs
    )
    if(-not(Test-FsDownloadAutoTuneEnabled -Config $Config)){return $null}
    $lock=Open-FsDownloadTuneLock -DatabasePath $DatabasePath
    if($null -eq $lock){throw 'Autotune-Sperre konnte nicht erworben werden.'}
    try{
        $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT * FROM download_tuning WHERE project_id=$ProjectId AND enabled=1 LIMIT 1;" -ExecutionTimeoutMs 5000)
        if($rows.Count -eq 0){return $null}
        $row=$rows[0]
        $safeSuccesses=[Math]::Max(1,$Successes)
        $safeBytes=[Math]::Max([long]0,$Bytes)
        $safeElapsed=[Math]::Max([long]1,$ElapsedMs)
        $filesPerSecond=[double]$safeSuccesses/($safeElapsed/1000.0)
        $bytesPerSecond=[double]$safeBytes/($safeElapsed/1000.0)
        $current=[Math]::Max(0,[int]$row.current_delay_ms)
        $floor=Get-FsDownloadAutoTuneMinDelayMs -Config $Config
        $minimumImprovement=Get-FsDownloadAutoTuneMinImprovementPct -Config $Config
        $previousFps=if($null -eq $row.previous_files_per_second){$null}else{[double]$row.previous_files_per_second}
        $previousDelay=if($null -eq $row.last_window_delay_ms){$null}else{[int]$row.last_window_delay_ms}
        $holdWindows=if($null -eq $row.hold_windows){0}else{[int]$row.hold_windows}
        $decrease=Get-FsDownloadDelayDecreaseAmount -DelayMs $current -Config $Config
        $candidate=[Math]::Max($floor,$current-$decrease)
        $next=$current
        $direction=0
        $nextHoldWindows=$holdWindows
        $improvementPct=$null

        if($current -le $floor){
            $reason="AutoTune-Floor $floor ms erreicht; Anfrageabstand bleibt unverändert. Durchsatz $([Math]::Round($filesPerSecond,3)) Datei(en)/s."
            $nextHoldWindows=$holdWindows+1
        }elseif($null -eq $previousFps -or $null -eq $previousDelay -or $previousFps -le 0){
            # First completed window establishes the baseline and performs one
            # bounded exploratory step. Every later reduction requires measured
            # throughput improvement.
            $next=$candidate
            $direction=if($next -lt $current){-1}else{0}
            $actualDecrease=[Math]::Max(0,$current-$next)
            $reason="AutoTune-Basisfenster: $([Math]::Round($filesPerSecond,3)) Datei(en)/s bei $current ms; einmaliger Testschritt auf $next ms (-$actualDecrease ms; Floor $floor ms)."
            $nextHoldWindows=0
        }else{
            $improvementPct=(($filesPerSecond-$previousFps)/$previousFps)*100.0
            if($improvementPct -ge $minimumImprovement){
                $next=$candidate
                $direction=if($next -lt $current){-1}else{0}
                $actualDecrease=[Math]::Max(0,$current-$next)
                $reason="Durchsatz stieg um $([Math]::Round($improvementPct,2)) % auf $([Math]::Round($filesPerSecond,3)) Datei(en)/s; Anfrageabstand $current -> $next ms (-$actualDecrease ms; Mindestverbesserung $minimumImprovement %, Floor $floor ms)."
                $nextHoldWindows=0
            }else{
                # Crucial HF65 change: no throughput gain means no further load
                # increase against Commons. Keep the current delay and measure
                # another complete window instead of blindly stepping down.
                $next=$current
                $direction=0
                $nextHoldWindows=$holdWindows+1
                $reason="Kein ausreichender Durchsatzgewinn ($([Math]::Round($improvementPct,2)) %, erforderlich $minimumImprovement %); Anfrageabstand bleibt bei $current ms."
            }
        }

        $bestDelay=if($null -eq $row.best_delay_ms){$current}else{[int]$row.best_delay_ms}
        $bestFiles=if($null -eq $row.best_files_per_second){0.0}else{[double]$row.best_files_per_second}
        $bestBytes=if($null -eq $row.best_bytes_per_second){0.0}else{[double]$row.best_bytes_per_second}
        if($filesPerSecond -gt $bestFiles){$bestDelay=$current;$bestFiles=$filesPerSecond;$bestBytes=$bytesPerSecond}
        $now=Get-FsUtcNowText
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
INSERT INTO download_tuning_samples(project_id,run_id,sample_type,delay_ms,next_delay_ms,direction,successes,bytes,elapsed_ms,files_per_second,bytes_per_second,status_code,note,created_at)
VALUES($ProjectId,$RunId,'window',$current,$next,$direction,$safeSuccesses,$safeBytes,$safeElapsed,$(ConvertTo-FsSqlLiteral $filesPerSecond),$(ConvertTo-FsSqlLiteral $bytesPerSecond),200,$(ConvertTo-FsSqlLiteral $reason),$(ConvertTo-FsSqlLiteral $now));
UPDATE download_tuning SET
 current_delay_ms=$next,
 direction=$direction,
 window_successes=0,
 window_bytes=0,
 window_started_at_ms=0,
 previous_files_per_second=$(ConvertTo-FsSqlLiteral $filesPerSecond),
 previous_bytes_per_second=$(ConvertTo-FsSqlLiteral $bytesPerSecond),
 last_window_delay_ms=$current,
 last_window_successes=$safeSuccesses,
 last_window_elapsed_ms=$safeElapsed,
 last_window_files_per_second=$(ConvertTo-FsSqlLiteral $filesPerSecond),
 last_window_bytes_per_second=$(ConvertTo-FsSqlLiteral $bytesPerSecond),
 last_window_at=$(ConvertTo-FsSqlLiteral $now),
 last_decision_at=$(ConvertTo-FsSqlLiteral $now),
 best_delay_ms=$bestDelay,
 best_files_per_second=$(ConvertTo-FsSqlLiteral $bestFiles),
 best_bytes_per_second=$(ConvertTo-FsSqlLiteral $bestBytes),
 hold_windows=$nextHoldWindows,
 burst_open=0,
 cooldown_until_ms=0,
 last_stable_delay_ms=$current,
 last_change_reason=$(ConvertTo-FsSqlLiteral $reason),
 updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND enabled=1;
COMMIT;
"@ -ExecutionTimeoutMs 15000 | Out-Null
    }finally{$lock.Dispose()}
    return Get-FsDownloadAutoTuneStatus -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $DatabasePath
}

function Register-FsDownloadAutoTuneThrottle {
    param(
        [int]$ProjectId,[int]$RunId,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath,[int]$StatusCode=429,
        [int]$RetryAfterSeconds=0,[string]$Note
    )
    if(-not(Test-FsDownloadAutoTuneEnabled -Config $Config)){return $null}
    $lock=Open-FsDownloadTuneLock -DatabasePath $DatabasePath
    if($null -eq $lock){return $null}
    $isNewBurst=$false
    $forcedPauseSeconds=20
    $burstNumber=0
    $increase=0
    try{
        $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT * FROM download_tuning WHERE project_id=$ProjectId AND enabled=1 LIMIT 1;" -ExecutionTimeoutMs 5000)
        if($rows.Count -eq 0){return $null}
        $row=$rows[0]
        $nowMs=Get-FsUnixMilliseconds
        $now=Get-FsUtcNowText
        $burstOpen=($null -ne $row.burst_open -and [int]$row.burst_open -eq 1)
        $isNewBurst=(-not $burstOpen)
        $previousBursts=if($null -eq $row.throttle_bursts){0}else{[int]$row.throttle_bursts}
        $burstNumber=if($isNewBurst){$previousBursts+1}else{[Math]::Max(1,$previousBursts)}
        $current=[Math]::Max(0,[int]$row.current_delay_ms)
        $increase=Get-FsDownloadDelayIncreaseAmount -DelayMs $current -Config $Config
        $next=if($isNewBurst){$current+$increase}else{$current}
        $basePause=if($Config.Download.ContainsKey('ThrottlePauseSeconds')){[Math]::Max(1,[int]$Config.Download.ThrottlePauseSeconds)}else{20}
        $forcedPauseSeconds=[Math]::Max($basePause,[Math]::Max(0,$RetryAfterSeconds))
        $cooldownUntilMs=$nowMs+([long]$forcedPauseSeconds*1000)
        $recovery=Get-FsDownloadBurstRecoverySettings -Config $Config
        $reason=if($isNewBurst){
            "HTTP 429-Burst ${burstNumber}: Anfrageabstand $current -> $next ms (+$increase ms, gemäßigt); gemeinsame ${forcedPauseSeconds}s-Pause; danach Stabilisierung mit $([int]$recovery.Successes) Erfolgen und $([int]$recovery.Seconds)s ohne neue 429."
        }else{
            "Weiterer HTTP 429 im noch offenen Burst ${burstNumber}: Anfrageabstand bleibt $current ms; gemeinsame Pause wird um ${forcedPauseSeconds}s erneuert."
        }
        $noteText=if([string]::IsNullOrWhiteSpace($Note)){$reason}else{"$reason | $Note"}
        if($isNewBurst){
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
INSERT INTO download_tuning_samples(project_id,run_id,sample_type,delay_ms,next_delay_ms,direction,successes,bytes,elapsed_ms,files_per_second,bytes_per_second,status_code,note,created_at)
VALUES($ProjectId,$RunId,'throttle',$current,$next,1,0,0,0,NULL,NULL,$StatusCode,$(ConvertTo-FsSqlLiteral $noteText),$(ConvertTo-FsSqlLiteral $now));
UPDATE download_tuning SET
 run_id=$RunId,current_delay_ms=$next,direction=1,
 window_successes=0,window_bytes=0,window_started_at_ms=0,
 previous_files_per_second=NULL,previous_bytes_per_second=NULL,
 hold_windows=0,throttle_bursts=$burstNumber,burst_open=1,
 cooldown_until_ms=$cooldownUntilMs,total_429=total_429+1,
 last_429_at_ms=$nowMs,last_429_at=$(ConvertTo-FsSqlLiteral $now),
 last_change_reason=$(ConvertTo-FsSqlLiteral $reason),last_decision_at=$(ConvertTo-FsSqlLiteral $now),updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId;
COMMIT;
"@ -ExecutionTimeoutMs 10000 | Out-Null
        }else{
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
UPDATE download_tuning SET
 run_id=$RunId,burst_open=1,cooldown_until_ms=MAX(cooldown_until_ms,$cooldownUntilMs),
 total_429=total_429+1,last_429_at_ms=$nowMs,last_429_at=$(ConvertTo-FsSqlLiteral $now),
 window_successes=0,window_bytes=0,window_started_at_ms=0,
 last_change_reason=$(ConvertTo-FsSqlLiteral $reason),updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId;
"@ -ExecutionTimeoutMs 10000 | Out-Null
        }
    }finally{$lock.Dispose()}
    $result=Get-FsDownloadAutoTuneStatus -ProjectId $ProjectId -SqlitePath $SqlitePath -DatabasePath $DatabasePath
    if($null -ne $result){
        $result | Add-Member -NotePropertyName ThrottleBurstStarted -NotePropertyValue ([bool]$isNewBurst) -Force
        $result | Add-Member -NotePropertyName ForcedPauseSeconds -NotePropertyValue ([int]$forcedPauseSeconds) -Force
        $result | Add-Member -NotePropertyName BurstNumber -NotePropertyValue ([int]$burstNumber) -Force
        $result | Add-Member -NotePropertyName DelayIncreaseMs -NotePropertyValue ([int]$(if($isNewBurst){$increase}else{0})) -Force
    }
    return $result
}

function Get-FsDownloadExceptionInfo {
    param([System.Exception]$Exception)

    $current=$Exception
    for($depth=0;$depth -lt 12 -and $null -ne $current;$depth++){
        if($current -is [System.AggregateException]){
            $flat=$current.Flatten()
            if($flat.InnerExceptions.Count -gt 0){
                $current=$flat.InnerExceptions[0]
                continue
            }
        }
        # Preserve WebException itself because the HTTP response/status hangs on
        # this wrapper; only invocation/reflection wrappers are unwrapped.
        if($current -is [System.Net.WebException]){break}
        if($null -ne $current.InnerException){
            $current=$current.InnerException
            continue
        }
        break
    }

    $statusCode=$null
    $statusDescription=$null
    $retryAfter=$null
    $webStatus=$null
    if($current -is [System.Net.WebException]){
        $webStatus=[string]$current.Status
        try{
            if($null -ne $current.Response -and $null -ne $current.Response.StatusCode){
                $statusCode=[int]$current.Response.StatusCode
                $statusDescription=[string]$current.Response.StatusDescription
                $header=[string]$current.Response.Headers['Retry-After']
                if(-not[string]::IsNullOrWhiteSpace($header)){
                    $seconds=0
                    if([int]::TryParse($header,[ref]$seconds)){
                        $retryAfter=[Math]::Max(1,$seconds)
                    }else{
                        $date=[DateTime]::MinValue
                        if([DateTime]::TryParse($header,[ref]$date)){
                            $retryAfter=[Math]::Max(1,[int][Math]::Ceiling(($date.ToUniversalTime()-[DateTime]::UtcNow).TotalSeconds))
                        }
                    }
                }
            }
        }catch{}
    }

    $rootType=if($null -eq $current){'System.Exception'}else{$current.GetType().FullName}
    $rootMessage=if($null -eq $current){[string]$Exception.Message}else{[string]$current.Message}
    $message=if($null -ne $statusCode){
        "HTTP $statusCode $statusDescription`: $rootMessage"
    }elseif(-not[string]::IsNullOrWhiteSpace($webStatus)){
        "WebException $webStatus`: $rootMessage"
    }else{
        "${rootType}: $rootMessage"
    }

    return [pscustomobject]@{
        RootException=$current
        RootType=$rootType
        RootMessage=$rootMessage
        Message=$message
        StatusCode=$statusCode
        RetryAfterSeconds=$retryAfter
        WebStatus=$webStatus
    }
}

function Invoke-FsDownloadFileWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Destination,
        [hashtable]$Headers=@{},
        [Parameter(Mandatory=$true)][string]$SqlitePath,
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [int]$ProjectId,
        [int]$RunId,
        [int]$MediaId,
        [string]$Worker,
        [hashtable]$Config,
        [scriptblock]$Heartbeat,
        [int]$DelayMs=1200,
        [int]$Retries=4,
        [int]$TimeoutSeconds=300
    )

    $configuredDelayMs=[Math]::Max(0,$DelayMs)
    $effectiveRetries=[Math]::Max(1,[Math]::Min(12,$Retries))
    $effectiveTimeoutSeconds=[Math]::Max(30,[Math]::Min(3600,$TimeoutSeconds))
    $gateName='commons-download'
    $recoverySlots=if($null -ne $Config -and $Config.ContainsKey('Download') -and $Config.Download.ContainsKey('Workers')){[Math]::Max(1,[Math]::Min(64,[int]$Config.Download.Workers))}else{4}
    $recoverySpacingMs=if($null -ne $Config -and $Config.ContainsKey('Download') -and $Config.Download.ContainsKey('RecoveryWorkerSpacingMs')){[Math]::Max(0,[int]$Config.Download.RecoveryWorkerSpacingMs)}else{3000}

    for($attempt=1;$attempt -le $effectiveRetries;$attempt++){
        $attemptWatch=[Diagnostics.Stopwatch]::StartNew()
        $gateWatch=[Diagnostics.Stopwatch]::StartNew()
        $httpWatch=$null
        $gateMs=0.0
        $httpMs=0.0
        $attemptDelayMs=if($null -ne $Config){Get-FsDownloadAutoTuneDelay -ProjectId $ProjectId -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath}else{$configuredDelayMs}
        $attemptStartedAtMs=0
        try{
            if($null -ne $Heartbeat){$null = & $Heartbeat}
            $gateResult=Acquire-FsDownloadApiSlot -DatabasePath $DatabasePath -DelayMs $attemptDelayMs -RecoverySpacingMs $recoverySpacingMs
            $gateMs=$gateWatch.Elapsed.TotalMilliseconds
            $attemptStartedAtMs=Get-FsUnixMilliseconds
            if($null -ne $Heartbeat){$null = & $Heartbeat}
            if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue}

            $httpWatch=[Diagnostics.Stopwatch]::StartNew()
            $wc=New-Object System.Net.WebClient
            try{
                foreach($key in $Headers.Keys){
                    if(([string]$key) -ieq 'Accept-Encoding'){continue}
                    $wc.Headers[[string]$key]=[string]$Headers[$key]
                }
                $task=$wc.DownloadFileTaskAsync([Uri]$Uri,$Destination)
                $nextHeartbeat=[DateTime]::UtcNow.AddSeconds(20)
                $deadline=[DateTime]::UtcNow.AddSeconds($effectiveTimeoutSeconds)
                while(-not $task.IsCompleted){
                    Start-Sleep -Milliseconds 500
                    if([DateTime]::UtcNow -ge $deadline){
                        try{$wc.CancelAsync()}catch{}
                        throw [TimeoutException]::new("Download-Timeout nach $effectiveTimeoutSeconds Sekunden: $Uri")
                    }
                    if([DateTime]::UtcNow -ge $nextHeartbeat){
                        if($null -ne $Heartbeat){$null = & $Heartbeat}
                        $nextHeartbeat=[DateTime]::UtcNow.AddSeconds(20)
                    }
                }
                $task.GetAwaiter().GetResult()
            }finally{
                if($null -ne $wc){$wc.Dispose()}
            }
            $httpMs=$httpWatch.Elapsed.TotalMilliseconds
            $bytes=if(Test-Path -LiteralPath $Destination){[long](Get-Item -LiteralPath $Destination).Length}else{0}
            if(Test-FsDiagnosticsEnabled){
                Write-FsPerformanceRecord -Record @{record_type='download';operation='original-file';task_id=$MediaId;attempt=$attempt;hits=$bytes;input_count=$attemptDelayMs;gate_ms=[Math]::Round($gateMs,3);http_parse_ms=[Math]::Round($httpMs,3);total_ms=[Math]::Round($attemptWatch.Elapsed.TotalMilliseconds,3);success=$true} | Out-Null
            }
            return [pscustomobject]@{Attempts=$attempt;StatusCode=200;DelayMs=$attemptDelayMs;Bytes=$bytes;StartedAtMs=$attemptStartedAtMs;GateMs=[Math]::Round($gateMs,3);HttpMs=[Math]::Round($httpMs,3);RecoverySlot=$(if($null -ne $gateResult){[bool]$gateResult.RecoverySlot}else{$false});TotalMs=[Math]::Round($attemptWatch.Elapsed.TotalMilliseconds,3)}
        }catch{
            $httpMs=if($null -ne $httpWatch){$httpWatch.Elapsed.TotalMilliseconds}else{0.0}
            $info=Get-FsDownloadExceptionInfo -Exception $_.Exception
            $status=$info.StatusCode
            $retryAfter=$info.RetryAfterSeconds
            $webStatus=[string]$info.WebStatus
            if(Test-FsDiagnosticsEnabled){
                Write-FsPerformanceRecord -Record @{record_type='download';operation='original-file';task_id=$MediaId;attempt=$attempt;input_count=$attemptDelayMs;gate_ms=[Math]::Round($gateMs,3);http_parse_ms=[Math]::Round($httpMs,3);total_ms=[Math]::Round($attemptWatch.Elapsed.TotalMilliseconds,3);success=$false;error=$info.Message} | Out-Null
            }
            $throttleState=$null
            if($status -eq 429 -and $null -ne $Config){
                try{
                    $throttleState=Register-FsDownloadAutoTuneThrottle -ProjectId $ProjectId -RunId $RunId -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath -StatusCode 429 -RetryAfterSeconds ([Math]::Max(0,[int]$retryAfter)) -Note $info.Message
                    if($null -ne $script:FsDownloadDelayCache){$script:FsDownloadDelayCache.Remove("$DatabasePath|$ProjectId")}
                }catch{
                    try{Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -Stage 'download' -Level 'warning' -Message ("Anfragesteuerung konnte HTTP 429 nicht verbuchen: {0}" -f $_.Exception.Message) -Details @{worker=$Worker;media_id=$MediaId}}catch{}
                }
            }
            $retryableStatus=($null -ne $status -and [int]$status -in @(408,425,429,500,502,503,504))
            $retryableWebStatus=($webStatus -in @('ConnectFailure','ConnectionClosed','KeepAliveFailure','NameResolutionFailure','PipelineFailure','ProxyNameResolutionFailure','ReceiveFailure','RequestCanceled','SendFailure','Timeout','UnknownError'))
            $retryableRootType=([string]$info.RootType -eq 'System.TimeoutException')
            $retryable=($retryableStatus -or $retryableWebStatus -or $retryableRootType)
            $globalCooldown=($status -eq 429 -or $null -ne $retryAfter)

            # Even the final failed attempt must extend the shared cooldown so the
            # remaining workers do not immediately continue hammering the server.
            if($status -eq 429){
                $immediatePause=if($null -ne $throttleState -and $null -ne $throttleState.ForcedPauseSeconds){[int]$throttleState.ForcedPauseSeconds}else{[Math]::Max(20,[Math]::Max(0,[int]$retryAfter))}
                [void](Set-FsDownloadApiCooldown -DatabasePath $DatabasePath -Seconds $immediatePause -RecoverySlots $recoverySlots -RecoverySpacingMs $recoverySpacingMs)
            }

            if(-not $retryable -or $attempt -ge $effectiveRetries){
                $final="Download fehlgeschlagen nach $attempt/$effectiveRetries Versuch(en): $($info.Message)"
                try{Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -Stage 'download' -Level 'error' -Message $final -Details @{url=$Uri;status=$status;web_status=$webStatus;attempt=$attempt;delay_ms=$attemptDelayMs}}catch{}
                if($status -in @(429,500,502,503,504)){
                    throw "Download-Infrastruktur: $final"
                }
                throw $final
            }

            $new429Burst=($status -eq 429 -and ($null -eq $throttleState -or [bool]$throttleState.ThrottleBurstStarted))
            $forcedPauseSeconds=if($null -ne $throttleState -and $null -ne $throttleState.ForcedPauseSeconds){[int]$throttleState.ForcedPauseSeconds}else{30}
            $cooldownSeconds=if($status -eq 429){
                # Every 429 while a burst is open renews the shared pause. Only a
                # successful file closes the burst and permits the next escalation.
                [Math]::Max($forcedPauseSeconds,[Math]::Max(0,[int]$retryAfter))
            }elseif($null -ne $retryAfter){
                [Math]::Max(1,[Math]::Min(300,[int]$retryAfter))
            }else{
                [Math]::Min(60,[Math]::Max(2,[Math]::Pow(2,$attempt)))
            }
            if($globalCooldown -and ($cooldownSeconds -gt 0)){
                $currentDelay=if($null -ne $Config){Get-FsDownloadAutoTuneDelay -ProjectId $ProjectId -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath}else{$attemptDelayMs}
                [void](Set-FsDownloadApiCooldown -DatabasePath $DatabasePath -Seconds $cooldownSeconds -RecoverySlots $recoverySlots -RecoverySpacingMs $recoverySpacingMs)
            }
            $retryMessage=if($status -eq 429 -and $new429Burst){
                "HTTP 429: gemeinsame ${cooldownSeconds}s-Zwangspause; danach Download-Retry $attempt/$effectiveRetries. $($info.Message)"
            }elseif($status -eq 429){
                "Weiterer HTTP 429 im offenen Burst; gemeinsame ${cooldownSeconds}s-Pause wird erneuert, ohne zusätzliche Delay-Erhöhung. Download-Retry $attempt/$effectiveRetries. $($info.Message)"
            }elseif($globalCooldown){
                "Download-Retry $attempt/$effectiveRetries nach gemeinsamem ${cooldownSeconds}s-Cooldown: $($info.Message)"
            }else{
                "Download-Retry $attempt/$effectiveRetries in ${cooldownSeconds}s: $($info.Message)"
            }
            try{Write-FsEvent -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -Stage 'download' -Level 'warning' -Message $retryMessage -Details @{url=$Uri;status=$status;web_status=$webStatus;global_cooldown=$globalCooldown;forced_pause_seconds=$cooldownSeconds;new_429_burst=$new429Burst;burst_number=$(if($null -ne $throttleState){$throttleState.BurstNumber}else{0});delay_ms=$attemptDelayMs}}catch{}
            if($null -ne $Heartbeat){$null = & $Heartbeat}
            if(-not $globalCooldown){
                $remaining=[int]$cooldownSeconds
                while($remaining -gt 0){
                    $slice=[Math]::Min(10,$remaining)
                    Start-Sleep -Seconds $slice
                    $remaining-=$slice
                    if($null -ne $Heartbeat){$null = & $Heartbeat}
                }
            }
        }
    }
}


function Get-FsSafeFilename {
    param([string]$Title,[string]$Sha1)
    $name=$Title -replace '^(?i)File:','';$invalid=[IO.Path]::GetInvalidFileNameChars();foreach($c in $invalid){$name=$name.Replace([string]$c,'_')};$name=[regex]::Replace($name,'\s+',' ').Trim();if($name.Length -gt 160){$ext=[IO.Path]::GetExtension($name);$base=[IO.Path]::GetFileNameWithoutExtension($name);$name=$base.Substring(0,[Math]::Min(140,$base.Length))+'_'+$Sha1.Substring(0,[Math]::Min(12,$Sha1.Length))+$ext};return $name
}


function Claim-FsDownloadTasks {
    param(
        [int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath,[int]$LeaseSeconds,[int]$Limit=4
    )
    $safeLimit=[Math]::Max(1,[Math]::Min(32,$Limit))
    $candidateLimit=[Math]::Max($safeLimit,$safeLimit*3)
    $maxAttempts=Get-FsTaskMaxAttempts -Config $Config
    $now=Get-FsUtcNowText
    $lease=[DateTime]::UtcNow.AddSeconds([Math]::Max(60,$LeaseSeconds)).ToString('o')
    $workerSql=ConvertTo-FsSqlLiteral $Worker
    $nowSql=ConvertTo-FsSqlLiteral $now
    $leaseSql=ConvertTo-FsSqlLiteral $lease

    # HF65: Claiming is deliberately optimized around SQLite's single-writer
    # model. Pending and retryable rows are read through separate narrow partial
    # indexes instead of scanning/sorting the mixed status queue. A worker also
    # reserves several tasks per BEGIN IMMEDIATE transaction (normally four),
    # amortising process startup and writer-lock cost over multiple downloads.
    # The final SELECT carries the media/download snapshot used by the worker,
    # removing one sqlite3 lookup process per downloaded file.
    return @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS temp.fs_download_claim;
CREATE TEMP TABLE fs_download_claim(
    seq INTEGER PRIMARY KEY,
    media_id INTEGER NOT NULL UNIQUE
);

-- Fast lane: the overwhelmingly common pending queue. The partial index is
-- ordered by project_id,media_id, so neither a mixed-status scan nor a temp
-- ORDER BY B-tree is needed.
INSERT INTO fs_download_claim(media_id)
SELECT pd.media_id
FROM project_downloads pd INDEXED BY ix_project_downloads_pending
WHERE pd.project_id=$ProjectId
  AND pd.status='pending'
  AND EXISTS(SELECT 1 FROM runs r WHERE r.id=$RunId AND r.status='running')
ORDER BY pd.media_id
LIMIT $candidateLimit;

-- Retry lane is touched only when the pending lane did not fill the look-ahead
-- block. attempts is the second key of the partial retry index.
INSERT OR IGNORE INTO fs_download_claim(media_id)
SELECT pd.media_id
FROM project_downloads pd INDEXED BY ix_project_downloads_failed_retry
WHERE pd.project_id=$ProjectId
  AND pd.status='failed'
  AND pd.attempts<$maxAttempts
  AND EXISTS(SELECT 1 FROM runs r WHERE r.id=$RunId AND r.status='running')
ORDER BY pd.attempts,pd.media_id
LIMIT MAX(0,$candidateLimit-(SELECT COUNT(*) FROM fs_download_claim));

INSERT OR IGNORE INTO downloads(media_id,status,owner_project_id,created_at,updated_at)
SELECT media_id,'pending',$ProjectId,$nowSql,$nowSql
FROM fs_download_claim;

-- A terminal global row whose verified payload no longer belongs to the
-- current media identity is not reusable. Repair it inside the same tiny claim
-- transaction so an identity change during a long run cannot create the
-- historical HF60 pending/running spin again.
UPDATE downloads
SET status='pending',
    local_path=NULL,
    bytes=NULL,
    verified_sha1=NULL,
    historical_complete=0,
    lease_owner=NULL,
    lease_until=NULL,
    attempts=0,
    last_error='HF65: terminaler Downloadzustand war nicht mehr sicher wiederverwendbar',
    updated_at=$nowSql
WHERE media_id IN (SELECT media_id FROM fs_download_claim)
  AND status IN ('done','historical')
  AND (
       (
         verified_sha1 IS NOT NULL AND verified_sha1<>''
         AND EXISTS(
             SELECT 1 FROM media m
             WHERE m.id=downloads.media_id
               AND m.sha1 IS NOT NULL AND m.sha1<>''
               AND lower(m.sha1)<>lower(downloads.verified_sha1)
         )
       )
       OR (
         COALESCE(historical_complete,0)<>1
         AND (local_path IS NULL OR local_path='')
       )
  );

-- Remove globally busy rows before applying the worker batch limit. Stale
-- leases remain claimable, terminal valid rows remain eligible for reuse.
DELETE FROM fs_download_claim
WHERE NOT EXISTS(
    SELECT 1
    FROM downloads d
    WHERE d.media_id=fs_download_claim.media_id
      AND (
          d.status IN ('done','historical','rejected')
          OR d.status IN ('pending','failed')
          OR (d.status='running' AND d.lease_until<=$nowSql)
      )
);

DELETE FROM fs_download_claim
WHERE seq NOT IN(
    SELECT seq FROM fs_download_claim ORDER BY seq LIMIT $safeLimit
);

UPDATE downloads
SET status='running',
    owner_project_id=$ProjectId,
    lease_owner=$workerSql,
    lease_until=$leaseSql,
    attempts=attempts+1,
    updated_at=$nowSql
WHERE media_id IN (SELECT media_id FROM fs_download_claim)
  AND (
      status IN ('pending','failed')
      OR (status='running' AND lease_until<=$nowSql)
  );

DELETE FROM fs_download_claim
WHERE NOT EXISTS(
    SELECT 1
    FROM downloads d
    WHERE d.media_id=fs_download_claim.media_id
      AND (
          d.status IN ('done','historical','rejected')
          OR (d.status='running' AND d.lease_owner=$workerSql)
      )
);

UPDATE project_downloads
SET status='running',
    lease_owner=$workerSql,
    lease_until=$leaseSql,
    attempts=attempts+1,
    updated_at=$nowSql
WHERE project_id=$ProjectId
  AND media_id IN (SELECT media_id FROM fs_download_claim);

-- HF65 prefetch: this is the complete snapshot required by
-- Invoke-FsDownloadWorkerItem. It eliminates the old per-file media/download
-- SELECT and therefore one sqlite3 process plus one reader lock per task.
SELECT
    pd.project_id,
    pd.media_id,
    pd.status,
    pd.lease_owner,
    pd.lease_until,
    pd.attempts,
    pd.last_error,
    pd.updated_at,
    d.status AS global_download_status,
    d.lease_owner AS global_download_owner,
    d.status AS download_status,
    d.local_path,
    d.bytes AS download_bytes,
    d.historical_complete,
    d.verified_sha1,
    m.title,
    m.canonical_title,
    m.sha1,
    m.size,
    m.url,
    CASE WHEN EXISTS(SELECT 1 FROM media_rejections r WHERE r.media_id=m.id)
          OR (m.page_id IS NOT NULL AND EXISTS(SELECT 1 FROM media_rejections r WHERE r.page_id=m.page_id))
          OR (m.sha1 IS NOT NULL AND m.sha1<>'' AND EXISTS(SELECT 1 FROM media_rejections r WHERE r.sha1=m.sha1 COLLATE NOCASE))
          OR (m.normalized_title IS NOT NULL AND m.normalized_title<>'' AND EXISTS(SELECT 1 FROM media_rejections r WHERE r.normalized_title=m.normalized_title COLLATE NOCASE))
         THEN 1 ELSE 0 END AS is_rejected,
    c.seq AS claim_sequence
FROM fs_download_claim c
JOIN project_downloads pd
  ON pd.project_id=$ProjectId AND pd.media_id=c.media_id
JOIN media m ON m.id=c.media_id
LEFT JOIN downloads d ON d.media_id=c.media_id
ORDER BY c.seq;

DROP TABLE temp.fs_download_claim;
COMMIT;
"@ -ExecutionTimeoutMs 60000 -ProgressLabel ("Download-Aufgaben blockweise beanspruchen; bis zu {0}" -f $safeLimit))
}

function Get-FsNextDownloadTask {
    param(
        [int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath,[int]$LeaseSeconds
    )
    $claimQueueVariable=Get-Variable -Name 'FsDownloadClaimQueues' -Scope Script -ErrorAction SilentlyContinue
    if($null -eq $claimQueueVariable -or $null -eq $claimQueueVariable.Value){
        $script:FsDownloadClaimQueues=@{}
    }
    $queueKey="$DatabasePath|$ProjectId|$RunId|$Worker"
    if(-not $script:FsDownloadClaimQueues.ContainsKey($queueKey)){
        $script:FsDownloadClaimQueues[$queueKey]=New-Object Collections.Queue
    }
    $queue=$script:FsDownloadClaimQueues[$queueKey]
    if($queue.Count -eq 0){
        # HF65: a worker that has exhausted its local claim block first commits
        # any underfilled completion batch. Thus result writes are grouped while
        # no successful file remains invisible indefinitely.
        [void](Flush-FsDownloadCompletionQueue -ProjectId $ProjectId -Worker $Worker -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath)
        $batchSize=if($Config.Download.ContainsKey('ClaimBatchSize')){[Math]::Max(1,[Math]::Min(32,[int]$Config.Download.ClaimBatchSize))}else{4}
        $claimed=@(Claim-FsDownloadTasks -ProjectId $ProjectId -RunId $RunId -Worker $Worker -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LeaseSeconds $LeaseSeconds -Limit $batchSize)
        foreach($row in $claimed){$queue.Enqueue($row)}
    }
    if($queue.Count -eq 0){return @()}
    return @($queue.Dequeue())
}

function Complete-FsDownloadWorkItem {
    param(
        [int]$ProjectId,[int]$MediaId,[string]$Worker,
        [string]$ProjectStatus,[string]$DownloadStatus,
        [string]$SqlitePath,[string]$DatabasePath,
        [AllowNull()][string]$LocalPath,
        [Nullable[long]]$Bytes,
        [AllowNull()][string]$VerifiedSha1,
        [Nullable[int]]$HistoricalComplete,
        [AllowNull()][string]$Error,
        [switch]$SkipDownloadUpdate
    )
    $now=Get-FsUtcNowText
    $workerSql=ConvertTo-FsSqlLiteral $Worker
    $downloadSql=''
    if(-not $SkipDownloadUpdate){
        $sets=New-Object Collections.Generic.List[string]
        $sets.Add("status=$(ConvertTo-FsSqlLiteral $DownloadStatus)")
        $sets.Add('lease_owner=NULL')
        $sets.Add('lease_until=NULL')
        $sets.Add("last_error=$(ConvertTo-FsSqlLiteral $Error)")
        $sets.Add("updated_at=$(ConvertTo-FsSqlLiteral $now)")
        if($PSBoundParameters.ContainsKey('LocalPath')){$sets.Add("local_path=$(ConvertTo-FsSqlLiteral $LocalPath)")}
        if($PSBoundParameters.ContainsKey('Bytes')){$sets.Add("bytes=$(ConvertTo-FsSqlLiteral $Bytes)")}
        if($PSBoundParameters.ContainsKey('VerifiedSha1')){$sets.Add("verified_sha1=$(ConvertTo-FsSqlLiteral $VerifiedSha1)")}
        if($PSBoundParameters.ContainsKey('HistoricalComplete')){$sets.Add("historical_complete=$(ConvertTo-FsSqlLiteral $HistoricalComplete)")}
        $ownerClause=if($DownloadStatus -in @('done','failed','historical')){" AND (lease_owner=$workerSql OR lease_owner IS NULL)"}else{''}
        $downloadSql="UPDATE downloads SET "+($sets -join ',')+" WHERE media_id=$MediaId$ownerClause;"
    }
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
$downloadSql
UPDATE project_downloads
SET status=$(ConvertTo-FsSqlLiteral $ProjectStatus),
    lease_owner=NULL,
    lease_until=NULL,
    last_error=$(ConvertTo-FsSqlLiteral $Error),
    updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND media_id=$MediaId AND lease_owner=$workerSql;
COMMIT;
"@ -ExecutionTimeoutMs 60000 -ProgressLabel ("Download-Ergebnis atomar speichern: Medium {0}, Status {1}" -f $MediaId,$ProjectStatus) | Out-Null
    return $true
}


function Get-FsDownloadCompletionBatchSize {
    param([hashtable]$Config)
    if($null -ne $Config -and $Config.ContainsKey('Download') -and $Config.Download.ContainsKey('CompletionBatchSize')){
        return [Math]::Max(1,[Math]::Min(16,[int]$Config.Download.CompletionBatchSize))
    }
    return 4
}

function Flush-FsDownloadCompletionQueue {
    param(
        [int]$ProjectId,[string]$Worker,[hashtable]$Config,
        [string]$SqlitePath,[string]$DatabasePath
    )
    $queueVariable=Get-Variable -Name 'FsDownloadCompletionQueues' -Scope Script -ErrorAction SilentlyContinue
    if($null -eq $queueVariable -or $null -eq $queueVariable.Value){return 0}
    $queueKey="$DatabasePath|$ProjectId|$Worker"
    if(-not $script:FsDownloadCompletionQueues.ContainsKey($queueKey)){return 0}
    $queue=$script:FsDownloadCompletionQueues[$queueKey]
    if($null -eq $queue -or $queue.Count -eq 0){return 0}

    $items=@($queue.ToArray())
    $statements=New-Object Collections.Generic.List[string]
    foreach($item in $items){
        $workerSql=ConvertTo-FsSqlLiteral ([string]$item.Worker)
        $now=Get-FsUtcNowText
        if(-not [bool]$item.SkipDownloadUpdate){
            $sets=New-Object Collections.Generic.List[string]
            $sets.Add("status=$(ConvertTo-FsSqlLiteral ([string]$item.DownloadStatus))")
            $sets.Add('lease_owner=NULL')
            $sets.Add('lease_until=NULL')
            $sets.Add("last_error=$(ConvertTo-FsSqlLiteral $item.Error)")
            $sets.Add("updated_at=$(ConvertTo-FsSqlLiteral $now)")
            if([bool]$item.HasLocalPath){$sets.Add("local_path=$(ConvertTo-FsSqlLiteral $item.LocalPath)")}
            if([bool]$item.HasBytes){$sets.Add("bytes=$(ConvertTo-FsSqlLiteral $item.Bytes)")}
            if([bool]$item.HasVerifiedSha1){$sets.Add("verified_sha1=$(ConvertTo-FsSqlLiteral $item.VerifiedSha1)")}
            if([bool]$item.HasHistoricalComplete){$sets.Add("historical_complete=$(ConvertTo-FsSqlLiteral $item.HistoricalComplete)")}
            $ownerClause=if(([string]$item.DownloadStatus) -in @('done','failed','historical')){" AND (lease_owner=$workerSql OR lease_owner IS NULL)"}else{''}
            $statements.Add("UPDATE downloads SET "+($sets -join ',')+" WHERE media_id=$([int]$item.MediaId)$ownerClause;")
        }
        $statements.Add(@"
UPDATE project_downloads
SET status=$(ConvertTo-FsSqlLiteral ([string]$item.ProjectStatus)),
    lease_owner=NULL,
    lease_until=NULL,
    last_error=$(ConvertTo-FsSqlLiteral $item.Error),
    updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND media_id=$([int]$item.MediaId) AND lease_owner=$workerSql;
"@)
    }

    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
$($statements -join "`n")
COMMIT;
"@ -ExecutionTimeoutMs 60000 -ProgressLabel ("Download-Ergebnisse blockweise speichern: {0}" -f $items.Count) | Out-Null

    for($i=0;$i -lt $items.Count;$i++){[void]$queue.Dequeue()}
    return $items.Count
}

function Submit-FsDownloadWorkItem {
    param(
        [int]$ProjectId,[int]$MediaId,[string]$Worker,
        [string]$ProjectStatus,[string]$DownloadStatus,
        [hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath,
        [AllowNull()][string]$LocalPath,
        [Nullable[long]]$Bytes,
        [AllowNull()][string]$VerifiedSha1,
        [Nullable[int]]$HistoricalComplete,
        [AllowNull()][string]$Error,
        [switch]$SkipDownloadUpdate
    )
    $queueVariable=Get-Variable -Name 'FsDownloadCompletionQueues' -Scope Script -ErrorAction SilentlyContinue
    if($null -eq $queueVariable -or $null -eq $queueVariable.Value){$script:FsDownloadCompletionQueues=@{}}
    $queueKey="$DatabasePath|$ProjectId|$Worker"
    if(-not $script:FsDownloadCompletionQueues.ContainsKey($queueKey)){
        $script:FsDownloadCompletionQueues[$queueKey]=New-Object Collections.Queue
    }
    $queue=$script:FsDownloadCompletionQueues[$queueKey]
    $queue.Enqueue([pscustomobject]@{
        ProjectId=$ProjectId;MediaId=$MediaId;Worker=$Worker
        ProjectStatus=$ProjectStatus;DownloadStatus=$DownloadStatus
        LocalPath=$LocalPath;HasLocalPath=$PSBoundParameters.ContainsKey('LocalPath')
        Bytes=$Bytes;HasBytes=$PSBoundParameters.ContainsKey('Bytes')
        VerifiedSha1=$VerifiedSha1;HasVerifiedSha1=$PSBoundParameters.ContainsKey('VerifiedSha1')
        HistoricalComplete=$HistoricalComplete;HasHistoricalComplete=$PSBoundParameters.ContainsKey('HistoricalComplete')
        Error=$Error;SkipDownloadUpdate=[bool]$SkipDownloadUpdate
    })
    $batchSize=Get-FsDownloadCompletionBatchSize -Config $Config
    if($queue.Count -ge $batchSize){
        [void](Flush-FsDownloadCompletionQueue -ProjectId $ProjectId -Worker $Worker -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath)
    }
    return $true
}


function Reset-FsDownloadClaimConflict {
    param(
        [int]$ProjectId,[int]$MediaId,[string]$Worker,[string]$GlobalStatus,
        [string]$SqlitePath,[string]$DatabasePath
    )
    $now=Get-FsUtcNowText
    $workerSql=ConvertTo-FsSqlLiteral $Worker
    $globalRepairSql=''
    if($GlobalStatus -in @('done','historical')){
        # A terminal row that reached the conflict branch failed the worker's
        # strict reuse test. Turn it into real pending work once instead of
        # bouncing project_downloads between running/pending forever.
        $globalRepairSql=@"
UPDATE downloads
SET status='pending',local_path=NULL,bytes=NULL,verified_sha1=NULL,
    historical_complete=0,lease_owner=NULL,lease_until=NULL,attempts=0,
    last_error='HF65: nicht wiederverwendbarer Terminalzustand beim Claim repariert',
    updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE media_id=$MediaId AND status IN ('done','historical');
"@
    }
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
$globalRepairSql
UPDATE project_downloads
SET status='pending',
    attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,
    lease_owner=NULL,lease_until=NULL,last_error=NULL,
    updated_at=$(ConvertTo-FsSqlLiteral $now)
WHERE project_id=$ProjectId AND media_id=$MediaId
  AND status='running' AND lease_owner=$workerSql;
COMMIT;
"@ -ExecutionTimeoutMs 60000 -ProgressLabel ("Download-Claim-Konflikt freigeben: Medium {0}" -f $MediaId) | Out-Null
}

function ConvertTo-FsDownloadTimingResult {
    param([object[]]$Output)

    [object[]]$matches=@($Output | Where-Object {
        $null -ne $_ -and
        $null -ne $_.PSObject.Properties['GateMs'] -and
        $null -ne $_.PSObject.Properties['HttpMs'] -and
        $null -ne $_.PSObject.Properties['DelayMs'] -and
        $null -ne $_.PSObject.Properties['Attempts'] -and
        $null -ne $_.PSObject.Properties['Bytes']
    })
    if($matches.Count -ne 1){
        $shapes=@($Output | ForEach-Object {
            if($null -eq $_){'<null>'}
            else{
                $names=@($_.PSObject.Properties.Name)
                "{0}[{1}]" -f $_.GetType().FullName,($names -join ',')
            }
        })
        throw ("Download-Infrastruktur: Download-Timing-Ergebnis fehlt oder ist mehrdeutig; Ergebnisse={0}; Formen={1}" -f @($Output).Count,($shapes -join ' | '))
    }

    $source=$matches[0]
    # Return a new fixed-shape object. Downstream code no longer depends on
    # the concrete object type or property casing emitted by the pipeline.
    return [pscustomobject]@{
        GateMs=[double]$source.PSObject.Properties['GateMs'].Value
        HttpMs=[double]$source.PSObject.Properties['HttpMs'].Value
        DelayMs=[int]$source.PSObject.Properties['DelayMs'].Value
        Attempts=[int]$source.PSObject.Properties['Attempts'].Value
        Bytes=[long]$source.PSObject.Properties['Bytes'].Value
    }
}

function Invoke-FsDownloadWorkerItem {
    param([int]$ProjectId,[int]$RunId,[string]$Worker,[hashtable]$Config,[string]$SqlitePath,[string]$DatabasePath,[string]$MediaRoot,[hashtable]$Headers)

    $itemWatch=[Diagnostics.Stopwatch]::StartNew()
    $claimMs=0.0;$lookupMs=0.0;$prepareMs=0.0;$apiGateMs=0.0;$httpMs=0.0
    $moveMs=0.0;$hashMs=0.0;$finalizeMs=0.0
    $measuredBytes=[long]0;$measuredDelay=0;$measuredAttempts=0
    $outcome='nicht-gestartet';$itemError=$null;$id=0
    $successForProfile=$true

    try{
        $leaseSeconds=Get-FsWorkerLeaseSeconds -Stage 'download' -Config $Config
        $phase=[Diagnostics.Stopwatch]::StartNew()
        $task=@(Get-FsNextDownloadTask -ProjectId $ProjectId -RunId $RunId -Worker $Worker -Config $Config -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LeaseSeconds $leaseSeconds)
        $claimMs=$phase.Elapsed.TotalMilliseconds
        if($task.Count -eq 0){$outcome='keine-aufgabe';return $false}

        $t=$task[0];$id=[int]$t.media_id
        # HF62: Download claims already receive a four-hour lease. Renewing that lease every
        # 60 seconds made four download workers serialize on BEGIN IMMEDIATE while large
        # files were still transferring. Renew only halfway through the lease; normal
        # downloads therefore perform no heartbeat write at all.
        $downloadHeartbeatSeconds=[Math]::Max(900,[int][Math]::Floor($leaseSeconds/2.0))
        $heartbeat=New-FsWorkerHeartbeat -ProjectId $ProjectId -RunId $RunId -Stage 'download' -Worker $Worker -LeaseSeconds $leaseSeconds -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MinimumSeconds $downloadHeartbeatSeconds

        # HF65: Claim-FsDownloadTasks already returned the complete media and
        # global-download snapshot. The former SELECT m.*,downloads... spawned a
        # second sqlite3 process for every single file and cost measurable reader
        # time even before writer contention was considered.
        $m=$t
        # HF50: downloads.bytes is not a media column. Read the explicit alias
        # defensively so reused/historical rows remain StrictMode-safe even
        # when the stored byte count is NULL.
        $existingDownloadBytes=$null
        $downloadBytesProperty=$m.PSObject.Properties['download_bytes']
        if($null -ne $downloadBytesProperty -and $null -ne $downloadBytesProperty.Value){
            $existingDownloadBytes=[long]$downloadBytesProperty.Value
        }

        if([int]$m.is_rejected -eq 1 -or [string]$m.download_status -eq 'rejected'){
            $phase.Restart()
            [void](Submit-FsDownloadWorkItem -ProjectId $ProjectId -MediaId $id -Worker $Worker -Config $Config -ProjectStatus 'skipped' -DownloadStatus 'rejected' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LocalPath $null -HistoricalComplete 1 -Error 'Global verworfen')
            $finalizeMs+=$phase.Elapsed.TotalMilliseconds
            $outcome='global-verworfen'
            return $true
        }

        if(([string]$m.download_status -in @('done','historical')) -and
           (([string]::IsNullOrWhiteSpace([string]$m.sha1)) -or
            ([string]::IsNullOrWhiteSpace([string]$m.verified_sha1) -or
             ([string]$m.sha1).ToLowerInvariant() -eq ([string]$m.verified_sha1).ToLowerInvariant())) -and
           (([int]$m.historical_complete -eq 1) -or ($m.local_path -and (Test-Path -LiteralPath ([string]$m.local_path))))){
            if($null -ne $existingDownloadBytes){$measuredBytes=[long]$existingDownloadBytes}
            $phase.Restart()
            [void](Submit-FsDownloadWorkItem -ProjectId $ProjectId -MediaId $id -Worker $Worker -Config $Config -ProjectStatus 'reused' -DownloadStatus ([string]$m.download_status) -SqlitePath $SqlitePath -DatabasePath $DatabasePath -SkipDownloadUpdate)
            $finalizeMs+=$phase.Elapsed.TotalMilliseconds
            $outcome='bereits-vorhanden'
            return $true
        }

        if(-not [string]::IsNullOrWhiteSpace([string]$m.sha1)){
            $phase.Restart()
            $sameHash=Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT d.status,d.local_path,d.bytes,d.verified_sha1 FROM downloads d INDEXED BY ix_downloads_verified_sha1 WHERE d.verified_sha1 IS NOT NULL AND d.verified_sha1<>'' AND d.verified_sha1=$(ConvertTo-FsSqlLiteral $m.sha1) COLLATE NOCASE AND d.media_id<>$id AND d.historical_complete=1 AND d.status IN ('done','historical') ORDER BY CASE WHEN d.local_path IS NULL OR d.local_path='' THEN 1 ELSE 0 END,d.media_id LIMIT 1;"
            $lookupMs+=$phase.Elapsed.TotalMilliseconds
            if(@($sameHash).Count -gt 0){
                $h=$sameHash[0]
                if($null -ne $h.bytes){$measuredBytes=[long]$h.bytes}
                $phase.Restart()
                [void](Submit-FsDownloadWorkItem -ProjectId $ProjectId -MediaId $id -Worker $Worker -Config $Config -ProjectStatus 'reused' -DownloadStatus ([string]$h.status) -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LocalPath ([string]$h.local_path) -Bytes ([long]$h.bytes) -VerifiedSha1 ([string]$m.sha1) -HistoricalComplete 1)
                $finalizeMs+=$phase.Elapsed.TotalMilliseconds
                $outcome='hash-wiederverwendet'
                return $true
            }
        }

        # HF65 circuit breaker: a claim conflict is infrastructure/reconciliation
        # work, not a processed download. Repair terminal inconsistencies once,
        # release the project lease without consuming an attempt, and tell the
        # worker loop not to increment its processed counter.
        if([string]$m.download_status -ne 'running' -or [string]$t.global_download_owner -ne $Worker){
            $phase.Restart()
            Reset-FsDownloadClaimConflict -ProjectId $ProjectId -MediaId $id -Worker $Worker -GlobalStatus ([string]$m.download_status) -SqlitePath $SqlitePath -DatabasePath $DatabasePath
            $finalizeMs+=$phase.Elapsed.TotalMilliseconds
            Start-Sleep -Milliseconds 50
            $outcome='claim-konflikt-repariert'
            return '__FS_RETRY__'
        }

        try {
            & $heartbeat
            $phase.Restart()
            if(-not(Test-Path -LiteralPath $MediaRoot)){New-Item -ItemType Directory -Path $MediaRoot -Force|Out-Null}
            $sha=[string]$m.sha1
            if([string]::IsNullOrWhiteSpace($sha)){$sha=Get-FsSha256Text ([string]$m.title)}
            $sub=Join-Path $MediaRoot $sha.Substring(0,2)
            if(-not(Test-Path -LiteralPath $sub)){New-Item -ItemType Directory -Path $sub -Force|Out-Null}
            $destination=Join-Path $sub (Get-FsSafeFilename ([string]$(if($m.canonical_title){$m.canonical_title}else{$m.title})) $sha)
            $part=$destination+'.part'

            if(Test-Path -LiteralPath $destination){
                $length=(Get-Item -LiteralPath $destination).Length
                if(-not $m.size -or [long]$m.size -eq $length){
                    $prepareMs+=$phase.Elapsed.TotalMilliseconds
                    $measuredBytes=[long]$length
                    $phase.Restart()
                    [void](Submit-FsDownloadWorkItem -ProjectId $ProjectId -MediaId $id -Worker $Worker -Config $Config -ProjectStatus 'done' -DownloadStatus 'done' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LocalPath $destination -Bytes ([long]$length) -VerifiedSha1 ([string]$m.sha1) -HistoricalComplete 1)
                    $finalizeMs+=$phase.Elapsed.TotalMilliseconds
                    $outcome='datei-bereits-lokal'
                    return $true
                }
            }
            $prepareMs+=$phase.Elapsed.TotalMilliseconds

            $downloadDelayMs=if($Config.Download.ContainsKey('DelayMs')){[Math]::Max(0,[int]$Config.Download.DelayMs)}else{[Math]::Max(0,[int]$Config.Api.DelayMs)}
            $downloadRetries=if($Config.Download.ContainsKey('Retries')){[Math]::Max(1,[int]$Config.Download.Retries)}else{[Math]::Min(6,[int]$Config.Api.Retries)}
            $downloadTimeoutSeconds=if($Config.Download.ContainsKey('TimeoutSeconds')){[Math]::Max(30,[int]$Config.Download.TimeoutSeconds)}else{300}
            # HF50: PowerShell functions can accidentally emit more than their
            # intended return object. Capture the complete success stream and
            # select exactly the timing result instead of dereferencing an
            # arbitrary Object[]/incidental output.
            [object[]]$downloadOutput=@(Invoke-FsDownloadFileWithRetry -Uri ([string]$m.url) -Destination $part -Headers $Headers -SqlitePath $SqlitePath -DatabasePath $DatabasePath -ProjectId $ProjectId -RunId $RunId -MediaId $id -Worker $Worker -Config $Config -Heartbeat $heartbeat -DelayMs $downloadDelayMs -Retries $downloadRetries -TimeoutSeconds $downloadTimeoutSeconds)
            $downloadResult=ConvertTo-FsDownloadTimingResult -Output $downloadOutput
            $apiGateMs=[double]$downloadResult.GateMs
            $httpMs=[double]$downloadResult.HttpMs
            $measuredDelay=[int]$downloadResult.DelayMs
            $measuredAttempts=[int]$downloadResult.Attempts
            $measuredBytes=[long]$downloadResult.Bytes

            & $heartbeat
            $phase.Restart()
            if(Test-Path -LiteralPath $destination){Remove-Item -LiteralPath $destination -Force}
            Move-Item -LiteralPath $part -Destination $destination
            $length=(Get-Item -LiteralPath $destination).Length
            $moveMs+=$phase.Elapsed.TotalMilliseconds
            $measuredBytes=[long]$length

            if([bool]$Config.Download.VerifySha1 -and $m.sha1){
                $phase.Restart()
                $actual=(Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash.ToLowerInvariant()
                $hashMs+=$phase.Elapsed.TotalMilliseconds
                if($actual -ne ([string]$m.sha1).ToLowerInvariant()){throw 'SHA1 stimmt nicht überein'}
            }

            $phase.Restart()
            [void](Submit-FsDownloadWorkItem -ProjectId $ProjectId -MediaId $id -Worker $Worker -Config $Config -ProjectStatus 'done' -DownloadStatus 'done' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -LocalPath $destination -Bytes ([long]$length) -VerifiedSha1 ([string]$m.sha1) -HistoricalComplete 1)
            $finalizeMs+=$phase.Elapsed.TotalMilliseconds
            $outcome='neu-heruntergeladen'
            return $true
        } catch {
            $downloadError=[string]$_.Exception.Message
            $itemError=$downloadError
            if(Test-FsInfrastructureTaskError -Message $downloadError){
                $outcome='infrastrukturfehler';$successForProfile=$false
                throw
            }
            $phase.Restart()
            [void](Submit-FsDownloadWorkItem -ProjectId $ProjectId -MediaId $id -Worker $Worker -Config $Config -ProjectStatus 'failed' -DownloadStatus 'failed' -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Error $downloadError)
            $finalizeMs+=$phase.Elapsed.TotalMilliseconds
            $outcome='download-fehlgeschlagen';$successForProfile=$false

            if($downloadError -notmatch '(?i)HTTP (404|410)\b'){
                $errorSql=ConvertTo-FsSqlLiteral $downloadError
                [object[]]$sameError=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT COUNT(*) count FROM project_downloads WHERE project_id=$ProjectId AND status='failed' AND last_error=$errorSql;")
                if($sameError.Count -gt 0 -and [int]$sameError[0].count -ge 20){
                    throw "Download-Infrastruktur: Derselbe Downloadfehler trat bereits $([int]$sameError[0].count)-mal auf: $downloadError"
                }
            }
            return $true
        }
    }
    finally{
        if($id -gt 0 -and (Test-FsDiagnosticsEnabled)){
            $totalMs=$itemWatch.Elapsed.TotalMilliseconds
            $knownMs=$claimMs+$lookupMs+$prepareMs+$apiGateMs+$httpMs+$moveMs+$hashMs+$finalizeMs
            $otherMs=[Math]::Max(0.0,$totalMs-$knownMs)
            Write-FsPerformanceRecord -Record @{
                record_type='download_item'
                operation='download-item'
                task_id=$id
                query_text=$outcome
                attempt=$measuredAttempts
                hits=$measuredBytes
                input_count=$measuredDelay
                gate_ms=[Math]::Round($apiGateMs,3)
                http_parse_ms=[Math]::Round($httpMs,3)
                transform_ms=[Math]::Round($claimMs,3)
                sql_build_ms=[Math]::Round($lookupMs,3)
                bulk_sqlite_ms=[Math]::Round($prepareMs,3)
                lock_wait_ms=[Math]::Round($moveMs,3)
                sqlite_ms=[Math]::Round($hashMs,3)
                task_complete_ms=[Math]::Round($finalizeMs,3)
                json_parse_ms=[Math]::Round($otherMs,3)
                total_ms=[Math]::Round($totalMs,3)
                success=$successForProfile
                error=$itemError
            }
        }
    }
}

Export-ModuleMember -Function *-Fs*
