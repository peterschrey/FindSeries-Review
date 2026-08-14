# Installs the official SQLite command-line tool and initializes the V5 workspace.
[CmdletBinding()]
param(
    [string]$Workspace,
    [switch]$ForceSqliteDownload,
    [string]$SqlitePath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Configuration.psm1') -Force -DisableNameChecking
$Workspace=Resolve-FsConfiguredWorkspace -Workspace $Workspace -ApplicationRoot $PSScriptRoot
try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}catch{}
Import-Module (Join-Path $PSScriptRoot 'Modules\FindSeries.Database.psm1') -Force

$tools=Join-Path $PSScriptRoot 'Tools'
if(-not(Test-Path -LiteralPath $tools)){New-Item -ItemType Directory -Path $tools -Force|Out-Null}
$target=Join-Path $tools 'sqlite3.exe'
if(-not [string]::IsNullOrWhiteSpace($SqlitePath)){$target=Resolve-FsAbsolutePath $SqlitePath}

if($ForceSqliteDownload -or -not(Test-Path -LiteralPath $target)){
    if(-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6){
        throw 'Automatischer Download ist in diesem Installer für Windows vorgesehen. Installiere sqlite3 über den Paketmanager und übergib -SqlitePath.'
    }

    Write-Host 'Offizielle SQLite-Downloadseite abrufen ...' -ForegroundColor Cyan
    $downloadPageUrl='https://www.sqlite.org/download.html'
    $page=(Invoke-WebRequest -Uri $downloadPageUrl -UseBasicParsing -TimeoutSec 60).Content

    # SQLite publishes a stable CSV table inside an HTML comment specifically for
    # script-driven downloads. Use its RELATIVE-URL instead of scraping the visible
    # link text, because current releases live below a year directory such as /2026/.
    $productMatch=[regex]::Match(
        $page,
        '(?im)^PRODUCT,[^,\r\n]+,(?<path>(?:\d{4}/)?sqlite-tools-win-x64-\d+\.zip),[^\r\n]*$'
    )

    $relative=$null
    if($productMatch.Success){
        $relative=$productMatch.Groups['path'].Value.Trim()
    }

    # Defensive fallback for a future page-format change. Prefer the current year
    # directory, then try the root URL used by older SQLite releases.
    $fileMatch=[regex]::Match($page,'sqlite-tools-win-x64-\d+\.zip')
    if([string]::IsNullOrWhiteSpace($relative) -and -not $fileMatch.Success){
        throw 'Auf der offiziellen SQLite-Seite wurde kein Windows-x64-Tools-Archiv gefunden.'
    }

    $downloadUrls=New-Object System.Collections.Generic.List[string]
    if(-not [string]::IsNullOrWhiteSpace($relative)){
        [void]$downloadUrls.Add(('https://www.sqlite.org/{0}' -f $relative.TrimStart('/')))
    }
    if($fileMatch.Success){
        $fileName=$fileMatch.Value
        $currentYear=[DateTime]::UtcNow.Year
        $yearUrl=('https://www.sqlite.org/{0}/{1}' -f $currentYear,$fileName)
        $rootUrl=('https://www.sqlite.org/{0}' -f $fileName)
        if(-not $downloadUrls.Contains($yearUrl)){[void]$downloadUrls.Add($yearUrl)}
        if(-not $downloadUrls.Contains($rootUrl)){[void]$downloadUrls.Add($rootUrl)}
    }

    $zip=Join-Path $env:TEMP ('findseries-sqlite-'+[Guid]::NewGuid().ToString('N')+'.zip')
    $extract=Join-Path $env:TEMP ('findseries-sqlite-'+[Guid]::NewGuid().ToString('N'))
    try{
        $downloaded=$false
        $lastDownloadError=$null
        foreach($url in $downloadUrls){
            try{
                Write-Host "SQLite herunterladen: $url" -ForegroundColor Gray
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 300
                $downloaded=$true
                break
            }
            catch{
                $lastDownloadError=$_
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                Write-Warning ("SQLite-Download über diese URL fehlgeschlagen; nächste offizielle Variante wird versucht: {0}" -f $url)
            }
        }
        if(-not $downloaded){
            $detail=if($null -ne $lastDownloadError){$lastDownloadError.Exception.Message}else{'unbekannter Fehler'}
            throw "SQLite konnte über keine der ermittelten offiziellen URLs heruntergeladen werden: $detail"
        }

        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $exe=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter sqlite3.exe|Select-Object -First 1
        if($null -eq $exe){throw 'sqlite3.exe wurde im offiziellen Archiv nicht gefunden.'}
        Copy-Item -LiteralPath $exe.FullName -Destination $target -Force
        Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
    }
    finally{
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if(-not(Test-Path -LiteralPath $target)){
    throw "sqlite3.exe wurde nicht gefunden: $target"
}

$version=& $target -version
if($LASTEXITCODE -ne 0){throw "sqlite3.exe konnte nicht ausgeführt werden: $target"}
Write-Host "SQLite: $version" -ForegroundColor Green
$init=Initialize-FsDatabase -Workspace $Workspace -SqlitePath $target
Write-Host "FindSeries V5.0.14 Hotfix 66 initialisiert: $($init.Paths.Root)" -ForegroundColor Green
Write-Host "Datenbank: $($init.Paths.Database)" -ForegroundColor Gray
