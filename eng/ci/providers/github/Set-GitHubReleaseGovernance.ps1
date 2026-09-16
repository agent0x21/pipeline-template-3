[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[\w.-]+/[\w.-]+$')][string]$Repository,
    [Parameter(Mandatory)][string[]]$DevReviewer,
    [Parameter(Mandatory)][string[]]$QaReviewer,
    [Parameter(Mandatory)][string[]]$ProductionReviewer,
    [switch]$AllowSelfReview
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ReleaseStore.ps1"
if (-not $env:GH_TOKEN) { throw 'Set GH_TOKEN to an administration-capable short-lived token. No token is accepted as a command-line argument.' }
function Get-Reviewers([string[]]$Names) {
    foreach ($name in $Names) {
        if ($name -match '^([^/]+)/([^/]+)$') {
            $team = & gh api "orgs/$($Matches[1])/teams/$($Matches[2])" | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw "Cannot resolve team '$name'." }
            @{ type = 'Team'; id = $team.id }
        } else {
            $user = & gh api "users/$name" | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw "Cannot resolve reviewer '$name'." }
            @{ type = 'User'; id = $user.id }
        }
    }
}
if ($PSCmdlet.ShouldProcess("$Repository/main", 'Require reviewed PRs and successful CI; disallow force pushes and deletion')) {
    Invoke-ReleaseApi 'branches/main/protection' -Method PUT -Body @{
        required_status_checks = @{ strict = $true; contexts = @('validate') }
        enforce_admins = $true
        required_pull_request_reviews = @{ required_approving_review_count = 1; dismiss_stale_reviews = $true; require_last_push_approval = $true }
        restrictions = $null; allow_force_pushes = $false; allow_deletions = $false; required_conversation_resolution = $true
    } | Out-Null
}
foreach ($name in @('DEV','QA','PROD')) {
    if ($PSCmdlet.ShouldProcess("$Repository/$name", 'Configure environment; main workflow ref only, separate required reviewers')) {
        $reviewers = @(if ($name -eq 'DEV') { Get-Reviewers $DevReviewer } elseif ($name -eq 'QA') { Get-Reviewers $QaReviewer } else { Get-Reviewers $ProductionReviewer })
        Invoke-ReleaseApi "environments/$name" -Method PUT -Body @{
            reviewers = $reviewers; prevent_self_review = (-not $AllowSelfReview)
            can_admins_bypass = $false; wait_timer = 0
            deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
        } | Out-Null
        $policies = Invoke-ReleaseApi "environments/$name/deployment-branch-policies"
        foreach ($policy in $policies.branch_policies) {
            if ($policy.name -ne 'main' -or $policy.type -ne 'branch') {
                Invoke-ReleaseApi "environments/$name/deployment-branch-policies/$($policy.id)" -Method DELETE | Out-Null
            }
        }
        if (-not @($policies.branch_policies | Where-Object { $_.name -eq 'main' -and $_.type -eq 'branch' }).Count) {
            Invoke-ReleaseApi "environments/$name/deployment-branch-policies" -Method POST -Body @{ name = 'main'; type = 'branch' } | Out-Null
        }
    }
}
if ($PSCmdlet.ShouldProcess($Repository, 'Protect component and release-set tags against updates and deletion')) {
    $rules = @{ name = 'Immutable release tags'; target = 'tag'; enforcement = 'active'
        conditions = @{ ref_name = @{ include = @('refs/tags/*/v*','refs/tags/release/*'); exclude = @() } }
        rules = @(@{ type = 'update' }, @{ type = 'deletion' }); bypass_actors = @()
    }
    $existing = @(Invoke-ReleaseApi 'rulesets?per_page=100' | Where-Object name -eq $rules.name)
    if ($existing.Count -gt 1) { throw 'Duplicate immutable release tag rulesets; resolve manually.' }
    if ($existing.Count) { Invoke-ReleaseApi "rulesets/$($existing[0].id)" -Method PUT -Body $rules | Out-Null }
    else { Invoke-ReleaseApi 'rulesets' -Method POST -Body $rules | Out-Null }
}
Write-Host 'Review and retire old promotion-branch rulesets separately. This script never deletes branches or old environments.'
