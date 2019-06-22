# TODO: Remove and make it automatically
param (
    [Parameter(Mandatory)]
    [ValidateSet('Issue', 'PR', 'Push', '__TESTS__', 'Scheduled')]
    [String] $Type
)

#region Variables pool
# Convert actual API response to object
$EVENT = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
# Event type for automatic handler detection
$EVENT_TYPE = $env:GITHUB_EVENT_NAME
# user/repo format
$REPOSITORY = $env:GITHUB_REPOSITORY
# Location of bucket
$BUCKET_ROOT = $env:GITHUB_WORKSPACE

# Backward compatability for manifests inside root of repository
$nestedBucket = Join-Path $BUCKET_ROOT 'bucket'
$MANIFESTS_LOCATION = if (Test-Path $nestedBucket) { $nestedBucket } else { $BUCKET_ROOT }
#endregion Variables pool

#region Function pool
#region ⬆⬆⬆⬆⬆⬆⬆⬆ OK ⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆
function Resolve-IssueTitle {
    <#
    .SYNOPSIS
        Parse issue title and return manifest name, version and problem.
    .PARAMETER Title
        Title to be parsed.
    .EXAMPLE
        Resolve-IssueTitle 'recuva@2.4: hash check failed'
    #>
    param([String] $Title)

    $result = $Title -match '(?<name>.+)@(?<version>.+):\s*(?<problem>.*)$'

    if ($result) {
        return $Matches.name, $Matches.version, $Matches.problem
    } else {
        return $null, $null, $null
    }
}

function Write-Log {
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    param ([String[]] $Message)

    Write-Output ''
    $Message | ForEach-Object { Write-Output "LOG: $_" }
}

function New-CheckListItem {
    <#
    .SYNOPSIS
        Helper functino for creating markdown check lists.
    .PARAMETER Check
        Name of check.
    .PARAMETER OK
        Check was met.
    #>
    param ([String] $Check, [Switch] $OK)

    if ($OK) {
        return "- [x] $Check"
    } else {
        return "- [ ] $Check"
    }
}

function Invoke-GithubRequest {
    <#
    .SYNOPSIS
        Invoke authenticated github API request.
    .PARAMETER Query
        Query to be executed.
    .PARAMETER Method
        Method to be used with request
    .PARAMETER Body
        Additional body to be send.
    #>
    param(
        [Parameter(Mandatory)]
        [String] $Query,
        [Microsoft.PowerShell.Commands.WebRequestMethod] $Method = 'Get',
        [Hashtable] $Body
    )

    $api_base_url = 'https://api.github.com'
    $headers = @{
        # Authorization token is neeeded for posting comments and to increase limit of requests
        'Authorization' = "token $env:GITHUB_TOKEN"
    }
    $parameters = @{
        'Headers' = $headers
        'Method'  = $Method
        'Uri'     = "$api_base_url/$Query"
    }

    Write-Debug $parameters.Uri

    if ($Body) { $parameters.Add('Body', (ConvertTo-Json $Body -Depth 8 -Compress)) }

    return Invoke-WebRequest @parameters
}

function Add-Comment {
    <#
    .SYNOPSIS
        Add comment into specific issue / PR.
    .PARAMETER ID
        ID of issue / PR.
    .PARAMETER Message
        String or array of string to be send as comment.
    #>
    param(
        [Int] $ID,
        [Alias('Comment')]
        [String[]] $Message
    )

    return Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/$ID/comments" -Method Post -Body @{ 'body' = ($Message -join "`r`n") }
}

function Add-Label {
    <#
    .SYNOPSIS
        Add label to issue / PR.
    .PARAMETER ID
        Id of issue / PR.
    .PARAMETER Label
        Label to be set.
    #>
    param([Int] $ID, [String[]] $Label)

    return Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/$ID/labels" -Method Post -Body @{ 'labels' = $Label }
}

function Get-AllChangedFilesInPR {
    <#
    .SYNOPSIS
        Get list of all changed files inside pull request.
    .PARAMETER ID
        ID of pull request.
    #>
    param([Int] $ID)

    $files = (Invoke-GithubRequest -Query "repos/$REPOSITORY/pulls/$ID/files").Content | ConvertFrom-Json
    return $files | Select-Object -Property filename, status
}

function Get-EnvironmentVariables {
    return Get-ChildItem Env: | Where-Object { $_.Name -ne 'GITHUB_TOKEN' }
}

function Close-Issue {
    <#
    .SYNOPSIS
        Close issue / PR.
    .PARAMETER ID
        ID of issue / PR.
    #>
    param([Int] $ID)

    return Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/$ID" -Method Patch -Body @{ 'state' = 'closed' }
}

function Remove-Label {
	<#
    .SYNOPSIS
        Remove label from issue / PR.
    .PARAMETER ID
        ID of issue / PR.
    .PARAMETER Label
        Array of labels to be removed.
    #>
	param([Int] $ID, [String[]] $Label)

	$responses = @()
	foreach ($lab in $Label) {
		$responses += Invoke-GithubRequest -Query "repos/$REPOSITORy/issues/$ID/labels/$label" -Method Delete
	}

	return $responses
}

#endregion ⬆⬆⬆⬆⬆⬆⬆⬆ OK ⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆

function Test-Hash {
    param (
        [Parameter(Mandatory = $true)]
        [String] $Manifest,
        [Int] $IssueID
    )

    $before = Get-Content (Join-Path $MANIFESTS_LOCATION "$Manifest.json") -Raw
    Write-Log 'BEFORE' $before

    & "$env:SCOOP_HOME\bin\checkhashes.ps1" -App $Manifest -Dir $MANIFESTS_LOCATION -Update
    $after = Get-Content (Join-Path $MANIFESTS_LOCATION "$Manifest.json") -Raw

    Write-Log 'AFTER' $after
    Write-Log ($after -eq $before)

    $status = git status --porcelain -uno
    Write-Log "Status: $status"

    Write-Log @('', (Get-Content (Join-Path $MANIFESTS_LOCATION "$Manifest.json") -Raw))

    if ($status -and $status.Count -eq 1) {
        Write-Log 'Verified'

        # TODO: Push if possible
        Add-Label -ID $IssueID -Label 'verified', 'hash-fix-needed'
        Add-Comment -ID $IssueID -Message 'You are right.'
    } else {
        Write-Log 'Cannot reproduce'

        Add-Comment -ID $IssueID -Message 'Cannot reproduce', '', "Please run ``scoop update; scoop uninstall $Manifest; scoop install $Manifest``"
        Remove-Label -ID $IssueID -Label 'hash-fix-needed'
        Close-Issue -ID $IssueID
    }
}


















function Initialize-Issue {
    Write-Log 'Issue initialized'

    Write-log "ACTION: $($EVENT.action)"

    # TODO: Uncomment before release / after proper debug
    # if ($EVENT.action -ne 'opened') {
    #     Write-Log "Only action 'opened' is supported."
    # }

    $title = $EVENT.issue.title
    $id = $EVENT.issue.number

    $problematicName, $problematicVersion, $problem = Resolve-IssueTitle $title
    if (($null -eq $problematicName) -or
        ($null -eq $problematicVersion) -or
        ($null -eq $problem)
    ) {
        Write-Log 'Not compatible issue title'
        exit 0
    }

    switch -Wildcard ($problem) {
        '*hash check*' {
            Write-Log 'Hash check failed'
            Test-Hash $problematicName $id
        }
        '*extact_dir*' { }
        '*download*failed*' { }
    }
    Write-Host $title $id $problematicName $problematicVersion $problem
}

function Initialize-PR {
    <#
    .SYNOPSIS
        Handle pull requests actions.
    #>
    Write-Log 'PR initialized'

    # TODO: Get all changed files in PR
    # Since binaries do not return any data on success flow needs to be this:
    # Run check with force param
    # if error, then just
    # git status, if changed
    # run checkver
    # run checkhashes
    # run formatjson?

    $EVENT | Format-Table | Out-String
    # $checksStatus = @()

    # & "$env:SCOOP_HOME\bin\checkver.ps1"
    # $status = if ($LASTEXITCODE -eq 0) { 'x' } else { ' ' }

    # $body = @{
    # 	'body' = (@(
    # 			"- Properties",
    # 			"    - [$status] Description",
    # 			"    - [$status] License",
    # 			"- [$status] Checkver functional",
    # 			"- [$status] Autoupdate working",
    # 			"- [$status] Hashes are correct",
    # 			"- [$status] Manifest is formatted"
    # 		) -join "`r`n")
    # }

    # Write-Log $body.body
}

function Initialize-Push {
    Write-Log 'Push initialized'
}

function Initialize-Scheduled {
    Write-Log 'Scheduled initialized'

    Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/7/comments" -Method Post -Body @{
        'body' = (@("Scheduled comment each hour - $(Get-Date)", 'WORKSPACE', "$(Get-ChildItem $env:GITHUB_WORKSPACE)") -join "`r`n")
    }
}
#endregion Function pool

#region Main
# For dot sourcing whole file inside tests
if ($Type -eq '__TESTS__') { return }

Write-Log (Get-EnvironmentVariables | ForEach-Object { "$($_.Key) | $($_.Value)" })

switch ($Type) {
    'Issue' { Initialize-Issue }
    'PR' { Initialize-PR }
    'Push' { Initialize-Push }
    'Scheduled' { Initialize-Scheduled }
}

Write-Host $EVENT_TYPE -f DarkRed
Write-Host $MANIFESTS_LOCATION -f DarkRed

# switch ($EVENT_TYPE) {
# 	'issues' { Initialize-Issue }
# 	'pull_requests' { Initialize-PR }
# 	'push' { Initialize-Push }
# 	'schedule' { Initialize-Scheduled }
# }
#endregion Main
