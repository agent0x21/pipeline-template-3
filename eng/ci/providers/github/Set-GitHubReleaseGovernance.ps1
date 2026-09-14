[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Reviewer,
    # Branches where humans work: normal pull-request review rules apply.
    [string[]]$DevelopmentBranches = @('dev'),
    # Branches the release pipeline owns. Humans never push to these; the pipeline
    # advances them onto the QA-approved commit.
    [string[]]$PromotionBranches = @('qa', 'main'),
    # GitHub App slug allowed to advance the promotion branches. The default is the
    # app behind GITHUB_TOKEN in Actions.
    [string]$AutomationApp = 'github-actions',
    [string[]]$Environments = @('development', 'beta', 'qa', 'rc', 'production', 'rc-approval', 'qa-approval', 'production-approval'),
    # Only these environments gate on a human, each a separate release decision:
    # 'rc-approval' (release manager, before QA receives the candidate), 'qa-approval'
    # (QA sign-off for a specific release identity), and 'production-approval'
    # (development manager, before main/production are advanced). The rest are
    # deployment boundaries, not decision points.
    [string[]]$ApprovalEnvironments = @('rc-approval', 'qa-approval', 'production-approval'),
    [ValidateRange(1, 6)][int]$RequiredApprovingReviewCount = 1,
    # Environments that build development artifacts, never release candidates. GitHub
    # itself is made to refuse the job before it starts when the triggering branch is
    # a promotion branch, rather than relying only on the in-workflow guard.
    [string[]]$DevelopmentArtifactEnvironments = @('development'),
    [switch]$PreventSelfReview,
    [switch]$AllowAdministratorsToBypass,
    [switch]$PreservePromotionCommits
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required. Install it from https://cli.github.com/ and run gh auth login.'
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
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

if ($PreservePromotionCommits) {
    # Optional. The pipeline advances qa and main itself and never squashes or
    # cherry-picks the approved commit, so this is no longer required for
    # traceability. It remains useful on development branches: a squash or rebase
    # merge into dev replaces commits that an in-flight candidate may reference.
    $mergePolicy = [pscustomobject]@{
        allow_merge_commit = $true
        allow_squash_merge = $false
        allow_rebase_merge = $false
    }
    if ($PSCmdlet.ShouldProcess("repository '$Repository'", 'allow only merge commits for pull requests')) {
        Invoke-GitHubApi -Method PATCH -Endpoint "repos/$Repository" -Body $mergePolicy | Out-Null
        Write-Host "Configured pull-request merge policy to preserve promotion commits."
    }
}

foreach ($branch in $DevelopmentBranches) {
    $endpoint = "repos/$Repository/branches/$([Uri]::EscapeDataString($branch))/protection"
    $body = [pscustomobject]@{
        required_status_checks = [pscustomobject]@{ strict = $true; contexts = @('validate') }
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
    if ($PSCmdlet.ShouldProcess("branch '$branch'", 'apply development branch protection')) {
        Invoke-GitHubApi -Method PUT -Endpoint $endpoint -Body $body | Out-Null
        Write-Host "Protected development branch: $branch"
    }
}

foreach ($branch in $PromotionBranches) {
    # qa and main are advanced by the pipeline onto the QA-approved commit. Write
    # access is restricted to the automation identity so a developer cannot move a
    # release branch by hand, and force pushes and deletions stay disabled so an
    # approved commit can never be rewritten out of history.
    $endpoint = "repos/$Repository/branches/$([Uri]::EscapeDataString($branch))/protection"
    $body = [pscustomobject]@{
        required_status_checks = $null
        enforce_admins = (-not $AllowAdministratorsToBypass)
        required_pull_request_reviews = $null
        restrictions = [pscustomobject]@{ users = @(); teams = @(); apps = @($AutomationApp) }
        required_linear_history = $false
        allow_force_pushes = $false
        allow_deletions = $false
        block_creations = $false
        required_conversation_resolution = $false
        lock_branch = $false
        allow_fork_syncing = $false
    }
    if ($PSCmdlet.ShouldProcess("branch '$branch'", "restrict pushes to the '$AutomationApp' automation identity")) {
        Invoke-GitHubApi -Method PUT -Endpoint $endpoint -Body $body | Out-Null
        Write-Host "Protected promotion branch: $branch (writable only by '$AutomationApp')"
    }
}

foreach ($environment in $Environments) {
    $endpoint = "repos/$Repository/environments/$([Uri]::EscapeDataString($environment))"
    $requiresApproval = $ApprovalEnvironments -contains $environment
    $excludesPromotionBranches = $DevelopmentArtifactEnvironments -contains $environment
    $body = [pscustomobject]@{
        wait_timer = 0
        prevent_self_review = [bool]$PreventSelfReview
        reviewers = $(if ($requiresApproval) { $reviewerPayload } else { @() })
        deployment_branch_policy = $(if ($excludesPromotionBranches) { [pscustomobject]@{ protected_branches = $false; custom_branch_policies = $true } } else { $null })
    }
    $action = if ($requiresApproval) { 'create/update required reviewers' } else { 'create/update deployment environment' }
    if ($PSCmdlet.ShouldProcess("environment '$environment'", $action)) {
        Invoke-GitHubApi -Method PUT -Endpoint $endpoint -Body $body | Out-Null
        Write-Host "Configured environment: $environment$(if ($requiresApproval) { ' (required reviewers)' })"
    }

    if ($excludesPromotionBranches) {
        # Idempotent: replace whatever branch policies exist with "every branch except
        # the promotion branches" so this job's environment can never be entered from
        # qa or main, regardless of how it was triggered.
        $policyEndpoint = "$endpoint/deployment-branch-policies"
        if ($PSCmdlet.ShouldProcess("environment '$environment'", "restrict deployment branches to all branches except $($PromotionBranches -join ', ')")) {
            $existingPolicies = (Invoke-GitHubApi -Method GET -Endpoint $policyEndpoint | ConvertFrom-Json).branch_policies
            foreach ($policy in @($existingPolicies)) {
                Invoke-GitHubApi -Method DELETE -Endpoint "$policyEndpoint/$($policy.id)" | Out-Null
            }
            Invoke-GitHubApi -Method POST -Endpoint $policyEndpoint -Body ([pscustomobject]@{ name = '*' }) | Out-Null
            foreach ($branch in $PromotionBranches) {
                Invoke-GitHubApi -Method POST -Endpoint $policyEndpoint -Body ([pscustomobject]@{ name = "!$branch" }) | Out-Null
            }
            Write-Host "Excluded promotion branches from environment: $environment ($($PromotionBranches -join ', '))"
        }
    }
}

Write-Host "Governance configured for $Repository."
