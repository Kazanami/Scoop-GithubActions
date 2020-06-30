Join-Path $PSScriptRoot '..\Helpers.psm1' | Import-Module

function Initialize-Hash {
    <#
    .SYNOPSIS
        Excavator alternative. Based on schedule execute of auto-pr binary.
    #>
    Write-Log 'Push initialized'

    $params = @{
        'Dir'         = $MANIFESTS_LOCATION
        'Upstream'    = "${REPOSITORY}:master"
        'Push'        = $true
        'SkipUpdated' = [bool] $env:SKIP_UPDATED
    }
    if ($env:SPECIAL_SNOWFLAKES) { $params.Add('SpecialSnowflakes', ($env:SPECIAL_SNOWFLAKES -split ',')) }

    & (Join-Path $BINARIES_FOLDER 'auto-pr.ps1') @params
    # TODO: Post some comment?? Or other way how to publish logs for non collaborators.

    Write-Log 'Push finished'
}

Export-ModuleMember -Function Initialize-Hash
