<#
    Corrects the GitHub rulesets on the promotion branches (qa, main).

    These branches are advanced only by the release pipeline (Update-PromotionBranch.ps1),
    which pushes a fast-forward, or occasionally a merge commit, directly - never through a
    pull request. Classic branch-protection `restrictions` (used by
    Set-GitHubReleaseGovernance.ps1 for organization-owned repositories) cannot express "only
    the automation identity may write" on a user-owned repository, so this repository uses
    rulesets instead.

    A prior setup copied the same ruleset onto dev, qa, and main, so qa/main ended up
    requiring pull-request review like a development branch - and the repository owner held
    an unconditional bypass on all three, so that requirement was silently skippable. That
    combination is what let manual "Merge Dev to QA" / "Merge QA to Main" pull requests land
    redundant merge commits on top of branches the pipeline had already fast-forwarded.

    This script does not attempt to distinguish the pipeline's push from the repository
    owner's own push - both currently authenticate as the same GitHub account, so no ruleset
    can tell them apart. What it does do: stop requiring a pull request on qa/main (matching
    the pipeline's actual write path) and remove the owner's bypass so that force pushes and
    branch deletion are blocked for everyone, including the owner, not just nominally.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$Repository,
    [string[]]$PromotionBranches = @('qa', 'main')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required. Install it from https://cli.github.com/ and run gh auth login.'
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string]$Method,
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
    return ($output -join "`n")
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated. Run gh auth login before running this script.' }

foreach ($branch in $PromotionBranches) {
    # No pull_request rule: the pipeline writes qa/main with a direct push, and requiring a
    # PR here is what let a redundant manual promotion PR appear to be "required" work.
    # No bypass_actors: without a bypass entry, the deletion/non_fast_forward rules below
    # apply to every writer, including the repository owner - there is no automation
    # identity distinct from the owner on this repository to carve out instead.
    $body = [pscustomobject]@{
        name = $branch
        target = 'branch'
        enforcement = 'active'
        conditions = [pscustomobject]@{
            ref_name = [pscustomobject]@{ include = @("refs/heads/$branch"); exclude = @() }
        }
        rules = @(
            [pscustomobject]@{ type = 'deletion' }
            [pscustomobject]@{ type = 'non_fast_forward' }
            [pscustomobject]@{ type = 'creation' }
            [pscustomobject]@{ type = 'update' }
        )
        bypass_actors = @()
    }

    $existing = (Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/rulesets" | ConvertFrom-Json) |
        Where-Object { $_.name -eq $branch -and $_.target -eq 'branch' } |
        Select-Object -First 1

    if ($existing) {
        if ($PSCmdlet.ShouldProcess("branch '$branch'", "update ruleset '$($existing.id)' to drop the pull-request requirement and the owner bypass")) {
            Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/rulesets/$($existing.id)" -Body $body | Out-Null
            Write-Host "Updated promotion ruleset for '$branch' (id $($existing.id)): no pull request required, no bypass."
        }
    } else {
        if ($PSCmdlet.ShouldProcess("branch '$branch'", 'create promotion ruleset: no pull request required, no bypass')) {
            Invoke-GitHubApi -Method POST -Endpoint "repos/$Repository/rulesets" -Body $body | Out-Null
            Write-Host "Created promotion ruleset for '$branch': no pull request required, no bypass."
        }
    }
}

Write-Host "Promotion branch rulesets corrected for $Repository."
Write-Host 'Note: the release pipeline and the repository owner push as the same GitHub identity here, so this cannot block a human from manually opening and merging a PR into qa/main - only GitHub org-level restrictions or a distinct automation identity for the pipeline can do that. This script only removes the incorrect PR requirement and the blanket bypass so force pushes and branch deletion are actually enforced.'
