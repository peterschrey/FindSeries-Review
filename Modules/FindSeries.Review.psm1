Set-StrictMode -Version 2.0

function Get-FsReviewConfigValue {
    param([hashtable]$Config,[string]$Name,$Default=$null)
    if($null -eq $Config -or -not $Config.ContainsKey('Review') -or -not($Config.Review -is [hashtable])){return $Default}
    if(-not $Config.Review.ContainsKey($Name)){return $Default}
    return $Config.Review[$Name]
}

function Test-FsReviewEnabled {
    param([hashtable]$Config)
    return [bool](Get-FsReviewConfigValue -Config $Config -Name 'Enabled' -Default $true)
}

function Get-FsReviewProjectRoot {
    param([Parameter(Mandatory=$true)][string]$Workspace,[Parameter(Mandatory=$true)][string]$ProjectSlug)
    return [IO.Path]::GetFullPath((Join-Path (Join-Path (Resolve-FsAbsolutePath $Workspace) 'Review') $ProjectSlug))
}

function Get-FsReviewSafeName {
    param([string]$Title,[string]$SourcePath,[int]$MaxLength=118)

    # Commons titles are external data. On Windows/.NET Framework even
    # GetExtension() throws when the input still contains path-invalid
    # characters such as quotes, angle brackets, pipes or control codes.
    # Therefore sanitize the complete title before calling any Path helper.
    $name=([string]$Title) -replace '^(?i)File:',''
    if([string]::IsNullOrWhiteSpace($name)){
        try{$name=[IO.Path]::GetFileName([string]$SourcePath)}catch{$name='Bild'}
    }
    foreach($c in [IO.Path]::GetInvalidFileNameChars()){$name=$name.Replace([string]$c,'_')}
    foreach($c in [IO.Path]::GetInvalidPathChars()){$name=$name.Replace([string]$c,'_')}
    $name=[regex]::Replace($name,'[\x00-\x1F]','_')
    $name=$name.Replace('/','_').Replace('\','_')
    $name=[regex]::Replace($name,'\s+',' ').Trim().TrimEnd([char[]]@('.',' '))
    if([string]::IsNullOrWhiteSpace($name)){$name='Bild'}

    # Prefer the extension of the real downloaded file. It is already a valid
    # local path and avoids treating dots inside unusual Commons titles as a
    # fabricated extension. Fall back to the sanitized title only if needed.
    $extension=''
    try{$extension=[IO.Path]::GetExtension([string]$SourcePath)}catch{$extension=''}
    if([string]::IsNullOrWhiteSpace($extension)){
        try{$extension=[IO.Path]::GetExtension($name)}catch{$extension=''}
    }
    $extension=([string]$extension).ToLowerInvariant()
    if($extension -notmatch '^\.[a-z0-9]{1,10}$'){$extension=''}

    $base=$name
    if(-not[string]::IsNullOrWhiteSpace($extension) -and $base.EndsWith($extension,[StringComparison]::OrdinalIgnoreCase)){
        $base=$base.Substring(0,$base.Length-$extension.Length)
    }else{
        try{$base=[IO.Path]::GetFileNameWithoutExtension($name)}catch{$base=$name}
    }
    $base=$base.Trim().TrimEnd([char[]]@('.',' '))
    if([string]::IsNullOrWhiteSpace($base)){$base='Bild'}
    $available=[Math]::Max(16,$MaxLength-$extension.Length)
    if($base.Length -gt $available){$base=$base.Substring(0,$available).Trim().TrimEnd([char[]]@('.',' '))}
    if([string]::IsNullOrWhiteSpace($base)){$base='Bild'}
    return $base+$extension
}

function New-FsReviewFile {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$ReviewPath,
        [ValidateSet('Auto','HardLink','Copy')][string]$LinkMode='Auto'
    )
    $directory=Split-Path -Parent $ReviewPath
    if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    if(Test-Path -LiteralPath $ReviewPath -PathType Leaf){return 'existing'}
    if($LinkMode -in @('Auto','HardLink')){
        try{
            New-Item -ItemType HardLink -Path $ReviewPath -Target $SourcePath -ErrorAction Stop|Out-Null
            return 'hardlink'
        }catch{
            if($LinkMode -eq 'HardLink'){throw}
        }
    }
    Copy-Item -LiteralPath $SourcePath -Destination $ReviewPath -ErrorAction Stop
    return 'copy'
}

function Initialize-FsReviewDirectory {
    param([string]$Root,[int]$ProjectId,[string]$ProjectName,[string]$ProjectSlug)
    $openRoot=Join-Path $Root 'Offen'
    if(-not(Test-Path -LiteralPath $openRoot)){New-Item -ItemType Directory -Path $openRoot -Force|Out-Null}
    $state=[ordered]@{
        format='FindSeries Review V1'
        project_id=$ProjectId
        project=$ProjectName
        slug=$ProjectSlug
        generated_at_utc=(Get-FsUtcNowText)
        behavior='Das Löschen einer exportierten Bilddatei markiert das Medium beim nächsten Sync global als verworfen.'
    }|ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $Root '.findseries-review-state.json'),$state,(New-Object Text.UTF8Encoding($false)))
    $readme=@"
FindSeries Review – $ProjectName

Arbeitsweise:
1. Öffne die Unterverzeichnisse unter "Offen" mit großen oder extra großen Symbolen.
2. Lösche unpassende Bilder mit Entf.
3. Starte FindSeries erneut oder führe Sync-FindSeriesReview.ps1 aus.

Wichtig:
- Bilder, die liegen bleiben, gelten weiterhin als offen/behalten.
- Gelöschte Bilder werden workspaceweit gesperrt und nicht erneut heruntergeladen,
  auch wenn sie später über andere Keywords, Sprachen, Kategorien oder Nachbarn gefunden werden.
- Dateien nicht umbenennen oder verschieben; beides wird wie Löschen behandelt.
- Die zentralen Hash-Verzeichnisse unter Workspace\Media nicht manuell bearbeiten.
"@
    [IO.File]::WriteAllText((Join-Path $Root 'README.txt'),$readme,(New-Object Text.UTF8Encoding($false)))
    return $openRoot
}

function Get-FsRejectedMediaPredicate {
    param([string]$MediaAlias='m')
    return @"
NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.media_id=$MediaAlias.id)
AND ($MediaAlias.page_id IS NULL OR $MediaAlias.page_id<=0 OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.page_id=$MediaAlias.page_id))
AND ($MediaAlias.sha1 IS NULL OR $MediaAlias.sha1='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.sha1=$MediaAlias.sha1 COLLATE NOCASE))
AND ($MediaAlias.normalized_title IS NULL OR $MediaAlias.normalized_title='' OR NOT EXISTS(SELECT 1 FROM media_rejections r WHERE r.normalized_title=$MediaAlias.normalized_title COLLATE NOCASE))
"@
}

function Get-FsReviewMatchingMediaRows {
    param(
        [string]$SqlitePath,[string]$DatabasePath,
        [int]$MediaId,[Nullable[long]]$PageId,[string]$Sha1,[string]$NormalizedTitle
    )
    $parts=New-Object Collections.Generic.List[string]
    if($MediaId -gt 0){$parts.Add("SELECT id FROM media WHERE id=$MediaId")}
    if($null -ne $PageId -and [long]$PageId -gt 0){$parts.Add("SELECT id FROM media WHERE page_id=$([long]$PageId)")}
    if(-not[string]::IsNullOrWhiteSpace($Sha1)){$parts.Add("SELECT id FROM media WHERE sha1=$(ConvertTo-FsSqlLiteral $Sha1) COLLATE NOCASE")}
    if(-not[string]::IsNullOrWhiteSpace($NormalizedTitle)){$parts.Add("SELECT id FROM media WHERE normalized_title=$(ConvertTo-FsSqlLiteral $NormalizedTitle) COLLATE NOCASE")}
    if($parts.Count -eq 0){return @()}
    $sql="SELECT DISTINCT id FROM (`n"+($parts -join "`nUNION ALL`n")+"`n) ORDER BY id;"
    return @(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql $sql)
}

function Add-FsGlobalMediaRejection {
    param(
        [string]$SqlitePath,[string]$DatabasePath,
        [int]$MediaId,[Nullable[long]]$PageId,[string]$Sha1,[string]$NormalizedTitle,
        [string]$ReviewPath,[string]$Reason='manual-delete',[string]$Source='review-sync'
    )
    $now=Get-FsUtcNowText
    $nowSql=ConvertTo-FsSqlLiteral $now
    $reasonSql=ConvertTo-FsSqlLiteral $Reason
    $sourceSql=ConvertTo-FsSqlLiteral $Source
    $pathSql=ConvertTo-FsSqlLiteral $ReviewPath
    $statements=New-Object Collections.Generic.List[string]
    if($MediaId -gt 0){$statements.Add("INSERT OR IGNORE INTO media_rejections(media_id,reason,source,review_path,rejected_at,updated_at) VALUES($MediaId,$reasonSql,$sourceSql,$pathSql,$nowSql,$nowSql);")}
    if($null -ne $PageId -and [long]$PageId -gt 0){$statements.Add("INSERT OR IGNORE INTO media_rejections(page_id,reason,source,review_path,rejected_at,updated_at) VALUES($([long]$PageId),$reasonSql,$sourceSql,$pathSql,$nowSql,$nowSql);")}
    if(-not[string]::IsNullOrWhiteSpace($Sha1)){$statements.Add("INSERT OR IGNORE INTO media_rejections(sha1,reason,source,review_path,rejected_at,updated_at) VALUES($(ConvertTo-FsSqlLiteral $Sha1),$reasonSql,$sourceSql,$pathSql,$nowSql,$nowSql);")}
    if(-not[string]::IsNullOrWhiteSpace($NormalizedTitle)){$statements.Add("INSERT OR IGNORE INTO media_rejections(normalized_title,reason,source,review_path,rejected_at,updated_at) VALUES($(ConvertTo-FsSqlLiteral $NormalizedTitle),$reasonSql,$sourceSql,$pathSql,$nowSql,$nowSql);")}
    if($statements.Count -gt 0){Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql ("BEGIN IMMEDIATE;`n"+($statements -join "`n")+"`nCOMMIT;")|Out-Null}
}

function Reject-FsReviewExport {
    param(
        [Parameter(Mandatory=$true)]$Export,
        [string]$SqlitePath,[string]$DatabasePath,
        [bool]$RemoveOriginal=$true
    )
    $mediaId=[int]$Export.media_id
    $pageId=$null
    if($null -ne $Export.page_id -and [string]$Export.page_id -ne ''){$pageId=[Nullable[long]]([long]$Export.page_id)}
    $sha1=([string]$Export.sha1).Trim().ToLowerInvariant()
    $title=([string]$Export.normalized_title).Trim().ToLowerInvariant()
    $reviewPath=[string]$Export.review_path

    Add-FsGlobalMediaRejection -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MediaId $mediaId -PageId $pageId -Sha1 $sha1 -NormalizedTitle $title -ReviewPath $reviewPath
    $matches=@(Get-FsReviewMatchingMediaRows -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MediaId $mediaId -PageId $pageId -Sha1 $sha1 -NormalizedTitle $title)
    $ids=@($matches|ForEach-Object{[int]$_.id}|Where-Object{$_ -gt 0}|Select-Object -Unique)
    if($ids.Count -eq 0){$ids=@($mediaId)}
    $idList=$ids -join ','

    $paths=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT DISTINCT review_path path,'review' kind FROM review_exports WHERE media_id IN ($idList) AND review_path IS NOT NULL
UNION
SELECT DISTINCT local_path path,'source' kind FROM downloads WHERE media_id IN ($idList) AND local_path IS NOT NULL;
"@)

    $now=Get-FsUtcNowText
    $reason='Global verworfen: manuell aus Review gelöscht'
    $removeOriginalSql=if($RemoveOriginal){1}else{0}
    $sql=@"
BEGIN IMMEDIATE;
UPDATE project_media SET selected=0,download_requested=0,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
UPDATE project_downloads SET status='skipped',lease_owner=NULL,lease_until=NULL,last_error=$(ConvertTo-FsSqlLiteral $reason),updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
UPDATE metadata_tasks SET status='skipped',lease_owner=NULL,lease_until=NULL,last_error=$(ConvertTo-FsSqlLiteral $reason),updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList) AND status<>'done';
UPDATE neighbor_tasks SET status='skipped',lease_owner=NULL,lease_until=NULL,last_error=$(ConvertTo-FsSqlLiteral $reason),updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
UPDATE downloads SET status='rejected',local_path=CASE WHEN $removeOriginalSql=1 THEN NULL ELSE local_path END,historical_complete=1,lease_owner=NULL,lease_until=NULL,last_error=$(ConvertTo-FsSqlLiteral $reason),updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
UPDATE review_exports SET status='rejected',rejected_at=$(ConvertTo-FsSqlLiteral $now),last_seen_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
COMMIT;
"@
    Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql $sql|Out-Null

    $removed=0;$removeErrors=0
    foreach($entry in $paths){
        $path=[string]$entry.path
        if([string]::IsNullOrWhiteSpace($path)){continue}
        if([string]$entry.kind -eq 'source' -and -not $RemoveOriginal){continue}
        if(Test-Path -LiteralPath $path -PathType Leaf){
            try{Remove-Item -LiteralPath $path -Force -ErrorAction Stop;$removed++}catch{$removeErrors++}
        }
        $part=$path+'.part'
        if([string]$entry.kind -eq 'source' -and $RemoveOriginal -and (Test-Path -LiteralPath $part -PathType Leaf)){
            try{Remove-Item -LiteralPath $part -Force -ErrorAction Stop;$removed++}catch{$removeErrors++}
        }
    }
    return [pscustomobject]@{MediaIds=$ids.Count;FilesRemoved=$removed;FileErrors=$removeErrors}
}

function Write-FsReviewManifest {
    param([int]$ProjectId,[string]$Root,[string]$SqlitePath,[string]$DatabasePath)
    $rows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT re.sequence_no,re.status,re.link_type,re.review_path,re.source_path,re.exported_at,re.last_seen_at,re.rejected_at,
       m.id media_id,m.page_id,m.title,m.sha1,pm.score
FROM review_exports re
LEFT JOIN media m ON m.id=re.media_id
LEFT JOIN project_media pm ON pm.project_id=re.project_id AND pm.media_id=re.media_id
WHERE re.project_id=$ProjectId
ORDER BY re.sequence_no;
"@)
    $manifestPath=Join-Path $Root '.findseries-review.jsonl'
    $lines=New-Object Collections.Generic.List[string]
    foreach($row in $rows){
        $manifestMediaId=$null;if($null -ne $row.media_id){$manifestMediaId=[int]$row.media_id}
        $manifestPageId=$null;if($null -ne $row.page_id){$manifestPageId=[long]$row.page_id}
        $manifestScore=$null;if($null -ne $row.score){$manifestScore=[int]$row.score}
        $record=[ordered]@{
            sequence=[int]$row.sequence_no
            status=[string]$row.status
            media_id=$manifestMediaId
            page_id=$manifestPageId
            sha1=[string]$row.sha1
            score=$manifestScore
            title=[string]$row.title
            review_path=[string]$row.review_path
            source_path=[string]$row.source_path
            link_type=[string]$row.link_type
            exported_at=[string]$row.exported_at
            rejected_at=[string]$row.rejected_at
        }
        $lines.Add(($record|ConvertTo-Json -Depth 5 -Compress))
    }
    $text=if($lines.Count -gt 0){($lines -join [Environment]::NewLine)+[Environment]::NewLine}else{''}
    [IO.File]::WriteAllText($manifestPath,$text,(New-Object Text.UTF8Encoding($false)))
    return $manifestPath
}

function Sync-FsReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][int]$ProjectId,
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Parameter(Mandatory=$true)][hashtable]$Config,
        [Parameter(Mandatory=$true)][string]$SqlitePath,
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [int]$MaxExports=-1,
        [switch]$Quiet
    )
    if(-not(Test-FsReviewEnabled -Config $Config)){
        return [pscustomobject]@{Enabled=$false;Rejected=0;Exported=0;Open=0;Remaining=0;Root=$null;FileErrors=0}
    }
    $projectRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT id,name,slug FROM projects WHERE id=$ProjectId LIMIT 1;")
    if($projectRows.Count -eq 0){throw "Review-Sync: Project-ID $ProjectId wurde nicht gefunden."}
    $project=$projectRows[0]
    $root=Get-FsReviewProjectRoot -Workspace $Workspace -ProjectSlug ([string]$project.slug)
    $statePath=Join-Path $root '.findseries-review-state.json'
    $batchSize=[Math]::Max(50,[int](Get-FsReviewConfigValue -Config $Config -Name 'BatchSize' -Default 500))
    $configuredMax=[int](Get-FsReviewConfigValue -Config $Config -Name 'MaxExportsPerSync' -Default 5000)
    if($MaxExports -lt 0){$MaxExports=$configuredMax}
    $linkMode=[string](Get-FsReviewConfigValue -Config $Config -Name 'LinkMode' -Default 'Auto')
    if($linkMode -notin @('Auto','HardLink','Copy')){$linkMode='Auto'}
    $removeOriginal=[bool](Get-FsReviewConfigValue -Config $Config -Name 'RemoveOriginalOnReject' -Default $true)

    $lockOwner='review-'+$PID+'-'+[Guid]::NewGuid().ToString('N')
    $lockName='review-project-'+$ProjectId
    if(-not(Acquire-FsNamedLock -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Name $lockName -Owner $lockOwner -LeaseSeconds 1800 -WaitSeconds 30)){throw 'Review-Sync konnte den exklusiven Review-Lock nicht erhalten.'}
    $rejected=0;$exported=0;$fileErrors=0;$restoredSources=0;$restoredReviewLinks=0
    try{
        # A missing project root/state file is treated as an accidental folder
        # removal, not as a mass rejection. Individual missing images are only
        # authoritative while the review state marker existed before this sync.
        $trustedReviewState=Test-Path -LiteralPath $statePath -PathType Leaf
        $openRoot=Initialize-FsReviewDirectory -Root $root -ProjectId $ProjectId -ProjectName ([string]$project.name) -ProjectSlug ([string]$project.slug)
        # Identity merges can discover a rejected SHA-1 only after metadata was
        # loaded. Such rows retain their path until this filesystem-aware sync
        # can remove the orphan safely.
        if($removeOriginal){
            $rejectedSources=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT media_id,local_path FROM downloads WHERE status='rejected' AND local_path IS NOT NULL AND local_path<>'';")
            $clearedRejectedIds=New-Object Collections.Generic.List[int]
            foreach($row in $rejectedSources){
                $path=[string]$row.local_path
                if(Test-Path -LiteralPath $path -PathType Leaf){try{Remove-Item -LiteralPath $path -Force -ErrorAction Stop}catch{$fileErrors++;continue}}
                $clearedRejectedIds.Add([int]$row.media_id)
            }
            if($clearedRejectedIds.Count -gt 0){
                $clearList=($clearedRejectedIds|Select-Object -Unique) -join ','
                Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "UPDATE downloads SET local_path=NULL WHERE media_id IN ($clearList) AND status='rejected';"|Out-Null
            }
        }

        # Clean up obsolete entries created by a later media-identity merge.
        $superseded=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT id,review_path FROM review_exports WHERE project_id=$ProjectId AND status='superseded';")
        foreach($row in $superseded){$path=[string]$row.review_path;if($path -and (Test-Path -LiteralPath $path -PathType Leaf)){try{Remove-Item -LiteralPath $path -Force -ErrorAction Stop}catch{$fileErrors++}}}
        if($superseded.Count -gt 0){Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "DELETE FROM review_exports WHERE project_id=$ProjectId AND status='superseded';"|Out-Null}

        $openExports=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT re.id,re.media_id,re.review_path,re.source_path,re.link_type,m.page_id,m.normalized_title,
       lower(COALESCE(NULLIF(m.sha1,''),NULLIF(d.verified_sha1,''))) sha1
FROM review_exports re
LEFT JOIN media m ON m.id=re.media_id
LEFT JOIN downloads d ON d.media_id=re.media_id
WHERE re.project_id=$ProjectId AND re.status='open'
ORDER BY re.sequence_no;
"@)
        $seenIds=New-Object Collections.Generic.List[int]
        foreach($row in $openExports){
            $reviewPath=[string]$row.review_path
            if(Test-Path -LiteralPath $reviewPath -PathType Leaf){
                $seenIds.Add([int]$row.id)
                $sourcePath=[string]$row.source_path
                if(-not[string]::IsNullOrWhiteSpace($sourcePath) -and -not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){
                    try{
                        $sourceDir=Split-Path -Parent $sourcePath
                        if(-not(Test-Path -LiteralPath $sourceDir)){New-Item -ItemType Directory -Path $sourceDir -Force|Out-Null}
                        New-Item -ItemType HardLink -Path $sourcePath -Target $reviewPath -ErrorAction Stop|Out-Null
                        $restoredSources++
                    }catch{$fileErrors++}
                }
                continue
            }
            if(-not $trustedReviewState){
                $sourcePath=[string]$row.source_path
                if(-not[string]::IsNullOrWhiteSpace($sourcePath) -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)){
                    $restoreMode=$linkMode
                    if([string]$row.link_type -eq 'hardlink'){$restoreMode='HardLink'}
                    elseif([string]$row.link_type -eq 'copy'){$restoreMode='Copy'}
                    try{
                        New-FsReviewFile -SourcePath $sourcePath -ReviewPath $reviewPath -LinkMode $restoreMode|Out-Null
                        $seenIds.Add([int]$row.id)
                        $restoredReviewLinks++
                    }catch{$fileErrors++}
                }else{$fileErrors++}
                continue
            }
            $result=Reject-FsReviewExport -Export $row -SqlitePath $SqlitePath -DatabasePath $DatabasePath -RemoveOriginal:$removeOriginal
            $rejected++
            $fileErrors+=[int]$result.FileErrors
        }
        if($seenIds.Count -gt 0){
            $now=Get-FsUtcNowText
            $seenList=($seenIds|Select-Object -Unique) -join ','
            Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql "UPDATE review_exports SET last_seen_at=$(ConvertTo-FsSqlLiteral $now) WHERE id IN ($seenList);"|Out-Null
        }

        $limitSql=if($MaxExports -gt 0){"LIMIT $MaxExports"}else{''}
        $predicate=Get-FsRejectedMediaPredicate -MediaAlias 'm'
        $candidates=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT pm.media_id,pm.score,COALESCE(NULLIF(m.canonical_title,''),m.title) title,m.page_id,m.sha1,d.local_path
FROM project_media pm
JOIN media m ON m.id=pm.media_id
JOIN downloads d ON d.media_id=pm.media_id
WHERE pm.project_id=$ProjectId
  AND pm.selected=1
  AND d.status IN ('done','historical')
  AND d.local_path IS NOT NULL AND d.local_path<>''
  AND $predicate
  AND NOT EXISTS(SELECT 1 FROM review_exports re WHERE re.project_id=$ProjectId AND re.media_id=pm.media_id AND re.status IN ('open','rejected'))
ORDER BY pm.score DESC,pm.media_id
$limitSql;
"@)
        $maxRows=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "SELECT COALESCE(MAX(sequence_no),0) max_sequence FROM review_exports WHERE project_id=$ProjectId;")
        $sequence=if($maxRows.Count -gt 0){[int]$maxRows[0].max_sequence}else{0}
        $created=New-Object System.Collections.ArrayList
        foreach($candidate in $candidates){
            $sourcePath=[string]$candidate.local_path
            if([string]::IsNullOrWhiteSpace($sourcePath) -or -not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){continue}
            $sequence++
            $batchStart=([Math]::Floor(($sequence-1)/$batchSize)*$batchSize)+1
            $batchEnd=$batchStart+$batchSize-1
            $batchFolder=Join-Path $openRoot (('{0:D6}-{1:D6}' -f [int]$batchStart,[int]$batchEnd))
            try{
                $safe=Get-FsReviewSafeName -Title ([string]$candidate.title) -SourcePath $sourcePath
                $filename=('{0:D6}__S{1:D3}__M{2}__{3}' -f $sequence,[Math]::Max(0,[int]$candidate.score),[int]$candidate.media_id,$safe)
                $reviewPath=Join-Path $batchFolder $filename
                $type=New-FsReviewFile -SourcePath $sourcePath -ReviewPath $reviewPath -LinkMode $linkMode
                [void]$created.Add([pscustomobject]@{MediaId=[int]$candidate.media_id;Sequence=$sequence;ReviewPath=$reviewPath;SourcePath=$sourcePath;LinkType=$type})
            }catch{
                $fileErrors++
                if(-not $Quiet){Write-Warning ("Review-Export für media_id {0} wurde übersprungen: {1}" -f [int]$candidate.media_id,$_.Exception.Message)}
            }
        }
        if($created.Count -gt 0){
            $now=Get-FsUtcNowText
            # Windows PowerShell 5.1 can throw 'Argument types do not match'
            # when @($genericListOfObject) is evaluated. Convert explicitly via
            # ArrayList.ToArray() so the chunk loop receives a real Object[].
            [object[]]$chunks=$created.ToArray()
            for($offset=0;$offset -lt $chunks.Count;$offset+=250){
                $values=New-Object Collections.Generic.List[string]
                foreach($item in @($chunks|Select-Object -Skip $offset -First 250)){
                    $values.Add("($ProjectId,$([int]$item.MediaId),$([int]$item.Sequence),$(ConvertTo-FsSqlLiteral ([string]$item.ReviewPath)),$(ConvertTo-FsSqlLiteral ([string]$item.SourcePath)),$(ConvertTo-FsSqlLiteral ([string]$item.LinkType)),'open',$(ConvertTo-FsSqlLiteral $now),$(ConvertTo-FsSqlLiteral $now))")
                }
                Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql ("INSERT OR IGNORE INTO review_exports(project_id,media_id,sequence_no,review_path,source_path,link_type,status,exported_at,last_seen_at) VALUES`n"+($values -join ",`n")+";")|Out-Null
            }
            $exported=$created.Count
        }

        $manifest=Write-FsReviewManifest -ProjectId $ProjectId -Root $root -SqlitePath $SqlitePath -DatabasePath $DatabasePath
        $stats=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT
 (SELECT COUNT(*) FROM review_exports WHERE project_id=$ProjectId AND status='open') open_count,
 (SELECT COUNT(*) FROM review_exports WHERE project_id=$ProjectId AND status='rejected') rejected_count,
 (SELECT COUNT(*) FROM project_media pm JOIN media m ON m.id=pm.media_id JOIN downloads d ON d.media_id=pm.media_id
   WHERE pm.project_id=$ProjectId AND pm.selected=1 AND d.status IN ('done','historical') AND d.local_path IS NOT NULL
     AND $predicate
     AND NOT EXISTS(SELECT 1 FROM review_exports re WHERE re.project_id=$ProjectId AND re.media_id=pm.media_id AND re.status IN ('open','rejected'))) remaining_count;
"@)
        $openCount=if($stats.Count){[int]$stats[0].open_count}else{0}
        $remaining=if($stats.Count){[int]$stats[0].remaining_count}else{0}
        if(-not $Quiet){
            Write-Host ("        [REVIEW] {0} neu exportiert; {1} gelöschte Bild(er) global verworfen; {2} offen; {3} noch nicht exportiert." -f $exported,$rejected,$openCount,$remaining) -ForegroundColor DarkCyan
            Write-Host ("                 {0}" -f $root) -ForegroundColor DarkGray
            if($restoredReviewLinks -gt 0){Write-Host ("        [REVIEW] Review-Struktur fehlte; {0} Link(s) wurden sicher rekonstruiert statt verworfen." -f $restoredReviewLinks) -ForegroundColor DarkYellow}
            if($restoredSources -gt 0){Write-Host ("        [REVIEW] {0} fehlende zentrale Quelldatei(en) aus vorhandenen Hardlinks wiederhergestellt." -f $restoredSources) -ForegroundColor DarkYellow}
            if($fileErrors -gt 0){Write-Warning ("Review-Sync: $fileErrors Dateioperation(en) konnten nicht ausgeführt werden.")}
        }
        return [pscustomobject]@{Enabled=$true;Rejected=$rejected;Exported=$exported;Open=$openCount;Remaining=$remaining;Root=$root;Manifest=$manifest;FileErrors=$fileErrors;RestoredSources=$restoredSources;RestoredReviewLinks=$restoredReviewLinks}
    }
    finally{Release-FsNamedLock -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Name $lockName -Owner $lockOwner}
}

function Restore-FsRejectedMedia {
    [CmdletBinding()]
    param(
        [string]$SqlitePath,[string]$DatabasePath,
        [int]$MediaId=0,[Nullable[long]]$PageId,[string]$Sha1,[string]$Title
    )
    $normalizedTitle=$null
    if(-not[string]::IsNullOrWhiteSpace($Title)){
        $value=Normalize-FsFileTitle $Title
        if($value){$normalizedTitle=$value.Substring(5).Replace('_',' ').ToLowerInvariant()}
    }
    $seedRows=@(Get-FsReviewMatchingMediaRows -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MediaId $MediaId -PageId $PageId -Sha1 $Sha1 -NormalizedTitle $normalizedTitle)
    $seedIds=@($seedRows|ForEach-Object{[int]$_.id}|Where-Object{$_ -gt 0}|Select-Object -Unique)
    if($seedIds.Count -gt 0){
        $seedList=$seedIds -join ','
        $identities=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql @"
SELECT id,page_id,lower(sha1) sha1,normalized_title FROM media WHERE id IN ($seedList);
"@)
        foreach($row in $identities){
            if($MediaId -le 0){$MediaId=[int]$row.id}
            if(($null -eq $PageId -or [long]$PageId -le 0) -and $null -ne $row.page_id){$PageId=[Nullable[long]]([long]$row.page_id)}
            if([string]::IsNullOrWhiteSpace($Sha1)){$Sha1=[string]$row.sha1}
            if([string]::IsNullOrWhiteSpace($normalizedTitle)){$normalizedTitle=[string]$row.normalized_title}
        }
    }
    $conditions=New-Object Collections.Generic.List[string]
    if($seedIds.Count -gt 0){$conditions.Add("media_id IN ("+($seedIds -join ',')+")")}
    elseif($MediaId -gt 0){$conditions.Add("media_id=$MediaId")}
    if($null -ne $PageId -and [long]$PageId -gt 0){$conditions.Add("page_id=$([long]$PageId)")}
    if(-not[string]::IsNullOrWhiteSpace($Sha1)){$conditions.Add("sha1=$(ConvertTo-FsSqlLiteral ($Sha1.Trim().ToLowerInvariant())) COLLATE NOCASE")}
    if(-not[string]::IsNullOrWhiteSpace($normalizedTitle)){$conditions.Add("normalized_title=$(ConvertTo-FsSqlLiteral $normalizedTitle) COLLATE NOCASE")}
    if($conditions.Count -eq 0){throw 'Keine passende Medienidentität für die Wiederherstellung gefunden.'}
    $where=$conditions -join ' OR '
    $removed=@(Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Query -Sql "DELETE FROM media_rejections WHERE $where RETURNING id;")

    $matches=@(Get-FsReviewMatchingMediaRows -SqlitePath $SqlitePath -DatabasePath $DatabasePath -MediaId $MediaId -PageId $PageId -Sha1 $Sha1 -NormalizedTitle $normalizedTitle)
    $ids=@($matches|ForEach-Object{[int]$_.id}|Where-Object{$_ -gt 0}|Select-Object -Unique)
    if($ids.Count -gt 0){
        $idList=$ids -join ','
        $now=Get-FsUtcNowText
        Invoke-FsSqlite -SqlitePath $SqlitePath -DatabasePath $DatabasePath -Sql @"
BEGIN IMMEDIATE;
UPDATE project_media SET selected=1,download_requested=0,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
UPDATE project_downloads SET status='pending',attempts=0,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
UPDATE downloads SET status='pending',historical_complete=0,lease_owner=NULL,lease_until=NULL,last_error=NULL,updated_at=$(ConvertTo-FsSqlLiteral $now) WHERE media_id IN ($idList);
DELETE FROM review_exports WHERE media_id IN ($idList) AND status='rejected';
COMMIT;
"@|Out-Null
    }
    return [pscustomobject]@{RemovedRejections=$removed.Count;ReactivatedMedia=$ids.Count;MediaIds=$ids}
}

Export-ModuleMember -Function *-Fs*
