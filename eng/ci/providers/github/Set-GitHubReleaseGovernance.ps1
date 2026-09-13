[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Reviewer,
    [string[]]$Branches = @('dev', 'qa', 'main'),
    [string[]]$Environments = @('release-beta', 'release-rc', 'release-stable', 'beta', 'rc', 'stable'),
    [ValidateRange(1, 6)][int]$RequiredApprovingReviewCount = 1,
    [switch]$PreventSelfReview,
    [switch]$AllowAdministratorsToBypass
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required. Install it from https://cli.github.com/ and run gh auth login.'
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        [object]$Body
    )
    $arguments = @('api', $Endpoint, '--method', $Method, '--header', 'Accept: application/vnd.github+json', '--header', 'X-GitHub-Api-Version: 2022-11-28')
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $output = $json | & gh @arguments '--input' '-' 2>&1
    } else {
        $output = & gh @arguments 2>&1
    }
    if ($LASTEXITCODE -ne 0) { throw "GitHub API request failed for '$Endpoint': $($output -join ' ')" }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-ReviewerReference {
    param([Parameter(Mandatory)][string]$Reference)
    if ($Reference -match '^([^/\s]+)/([^/\s]+)$') {
        $organization = $Matches[1]
        $teamSlug = $Matches[2]
        $idText = (Invoke-GitHubApi -Method GET -Endpoint "orgs/$organization/teams/$teamSlug" | Select-Object -Last 1) | ConvertFrom-Json
        return [pscustomobject]@{ type = 'Team'; id = [int64]$idText.id; reference = $Reference }
    }
    $user = (Invoke-GitHubApi -Method GET -Endpoint "users/$Reference" | Select-Object -Last 1) | ConvertFrom-Json
    return [pscustomobject]@{ type = 'User'; id = [int64]$user.id; reference = $Reference }
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated. Run gh auth login before running this script.' }

$reviewers = @($Reviewer | ForEach-Object { Get-ReviewerReference $_ })
$reviewerPayload = @($reviewers | ForEach-Object { [pscustomobject]@{ type = $_.type; id = $_.id } })

foreach ($branch in $Branches) {
    $endpoint = "repos/$Repository/branches/$([Uri]::EscapeDataString($branch))/protection"
    $body = [pscustomobject]@{
        required_status_checks = $null
        enforce_admins = (-not $AllowAdministratorsToBypass)
        required_pull_request_reviews = [pscustomobject]@{
            dismiss_stale_reviews = $true
            require_code_owner_reviews = $false
            required_approving_review_count = $RequiredApprovingReviewCount
            require_last_push_approval = $true
        }
        restrictions = $null
        required_linear_history = $false
        allow_force_pushes = $false
        allow_deletions = $false
        block_creations = $false
        required_conversation_resolution = $true
        lock_branch = $false
        allow_fork_syncing = $false
    }
    if ($PSCmdlet.ShouldProcess("branch '$branch'", 'apply GitHub branch protection')) {
        Invoke-GitHubApi -Method PUT -Endpoint $endpoint -Body $body | Out-Null
        Write-Host "Protected branch: $branch"
    }
}

foreach ($environment in $Environments) {
    $endpoint = "repos/$Repository/environments/$([Uri]::EscapeDataString($environment))"
    $body = [pscustomobject]@{
        wait_timer = 0
        prevent_self_review = [bool]$PreventSelfReview
        reviewers = $reviewerPayload
        deployment_branch_policy = $null
    }
    if ($PSCmdlet.ShouldProcess("environment '$environment'", 'create/update required reviewers')) {
        Invoke-GitHubApi -Method PUT -Endpoint $endpoint -Body $body | Out-Null
        Write-Host "Configured environment: $environment"
    }
}

Write-Host "Governance configured for $Repository."
