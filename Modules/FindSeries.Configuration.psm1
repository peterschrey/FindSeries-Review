# Shared local configuration for FindSeries entry scripts.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

function Resolve-FsConfiguredWorkspace {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Workspace,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$ApplicationRoot,
        [string]$SettingsPath
    )

    $root=[IO.Path]::GetFullPath($ApplicationRoot)

    function Resolve-ConfiguredPath {
        param([Parameter(Mandatory=$true)][string]$Value)
        $expanded=[Environment]::ExpandEnvironmentVariables($Value.Trim())
        if([string]::IsNullOrWhiteSpace($expanded)){return $null}
        if([IO.Path]::IsPathRooted($expanded)){return [IO.Path]::GetFullPath($expanded)}
        return [IO.Path]::GetFullPath((Join-Path $root $expanded))
    }

    # An explicit command-line value always wins.
    if(-not[string]::IsNullOrWhiteSpace($Workspace)){
        return Resolve-ConfiguredPath -Value $Workspace
    }

    if([string]::IsNullOrWhiteSpace($SettingsPath)){
        $SettingsPath=Join-Path $root 'Config\local.json'
    }elseif(-not[IO.Path]::IsPathRooted($SettingsPath)){
        $SettingsPath=Join-Path $root $SettingsPath
    }
    $SettingsPath=[IO.Path]::GetFullPath($SettingsPath)

    if(Test-Path -LiteralPath $SettingsPath -PathType Leaf){
        try{
            $settings=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json
        }catch{
            throw "Lokale FindSeries-Konfiguration ist ungültig: $SettingsPath`n$($_.Exception.Message)"
        }

        $configuredWorkspace=$null
        if($null -ne $settings -and $null -ne $settings.PSObject.Properties['Workspace']){
            $configuredWorkspace=[string]$settings.Workspace
        }
        if(-not[string]::IsNullOrWhiteSpace($configuredWorkspace)){
            return Resolve-ConfiguredPath -Value $configuredWorkspace
        }
    }

    return [IO.Path]::GetFullPath((Join-Path $root 'Workspace'))
}

Export-ModuleMember -Function Resolve-FsConfiguredWorkspace
