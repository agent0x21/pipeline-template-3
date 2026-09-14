<#
    Advances a protected source branch (qa, main) onto the QA-approved candidate
    commit without ever rewriting that commit.

    The candidate SHA is always supplied by the pipeline, never typed by a human.
    A fast-forward is preferred because it preserves the exact commit identity. If
    the branch has advanced independently, a merge commit is created with the
    branch tip as first parent and the approved commit as second parent, so the
    approved SHA stays in ancestry and remains the artifact source identity. The
    approved candidate is never cherry-picked, squashed, or rebased.

    Concurrency: the push is a plain (non-forced) ref update from a commit that
    descends from the observed branch head, so a competing promotion that moved
    the branch first causes this push to be rejected rather than overwritten.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Branch,
    [Parameter(Mandatory)][string]$CandidateSha,
    [string]$ExpectedSha = '',
    [string]$Remote = 'origin',
    [switch]$AllowMerge,
    [switch]$Push,
    [string]$CommitterName = 'release-automation',
    [string]$CommitterEmail = 'release-automation@users.noreply.github.com',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$safeDirectory = (Get-Location).Path

function Invoke-PromotionGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & git '-c' "safe.directory=$safeDirectory" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
    return @($output | ForEach-Object { [string]$_ })
}

function Test-Ancestor {
    param([Parameter(Mandatory)][string]$Ancestor, [Parameter(Mandatory)][string]$Descendant)
    & git '-c' "safe.directory=$safeDirectory" merge-base --is-ancestor $Ancestor $Descendant 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

$candidateSha = $CandidateSha.Trim().ToLowerInvariant()
if ($candidateSha -notmatch '^[0-9a-f]{40}$') { throw "The candidate SHA could not be determined unambiguously: '$CandidateSha'." }

Invoke-PromotionGit @('fetch', $Remote, '--tags', "+refs/heads/${Branch}:refs/remotes/$Remote/$Branch") | Out-Null
Invoke-PromotionGit @('cat-file', '-e', "$candidateSha^{commit}") | Out-Null

$remoteEntries = @(& git '-c' "safe.directory=$safeDirectory" ls-remote $Remote "refs/heads/$Branch" 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Unable to read '$Branch' from '$Remote': $($remoteEntries -join ' ')" }
$currentSha = ''
foreach ($line in $remoteEntries) {
    $parts = ([string]$line -split '\s+', 2)
    if ($parts.Count -eq 2 -and $parts[1] -eq "refs/heads/$Branch") { $currentSha = $parts[0].ToLowerInvariant() }
}

if ($ExpectedSha -and $currentSha -ne $ExpectedSha.Trim().ToLowerInvariant()) {
    throw "The '$Branch' ref changed during promotion: expected '$ExpectedSha' but '$Remote' now reports '$currentSha'. Re-run the promotion against the current head."
}

$strategy = Get-BranchAdvanceStrategy -CurrentSha $currentSha -CandidateSha $candidateSha `
    -CurrentIsAncestorOfCandidate ($currentSha -and (Test-Ancestor -Ancestor $currentSha -Descendant $candidateSha)) `
    -CandidateIsAncestorOfCurrent ($currentSha -and (Test-Ancestor -Ancestor $candidateSha -Descendant $currentSha))

if ($strategy -eq 'merge' -and -not $AllowMerge) {
    throw "'$Branch' has advanced to '$currentSha' and cannot fast-forward to the approved commit '$candidateSha'. Re-run with -AllowMerge to record a merge commit that preserves the approved commit in ancestry, or rebuild a candidate from the current branch head."
}

$resultSha = $candidateSha
$mergeCommit = $null
if ($strategy -eq 'merge') {
    Invoke-PromotionGit @('config', 'user.name', $CommitterName) | Out-Null
    Invoke-PromotionGit @('config', 'user.email', $CommitterEmail) | Out-Null
    Invoke-PromotionGit @('checkout', '--detach', $currentSha) | Out-Null
    $message = "Promote QA-approved $candidateSha into $Branch`n`nApproved-Commit: $candidateSha`nPromoted-Branch: $Branch"
    & git '-c' "safe.directory=$safeDirectory" merge --no-ff --no-edit -m $message $candidateSha 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        & git '-c' "safe.directory=$safeDirectory" merge --abort 2>&1 | Out-Null
        throw "The approved commit '$candidateSha' cannot be merged into '$Branch' without conflicts. Resolve the divergence before promoting."
    }
    $mergeCommit = (Invoke-PromotionGit @('rev-parse', 'HEAD') | Select-Object -First 1).ToLowerInvariant()
    if (-not (Test-Ancestor -Ancestor $candidateSha -Descendant $mergeCommit)) {
        throw "The promotion commit '$mergeCommit' does not contain the approved commit '$candidateSha'."
    }
    $resultSha = $mergeCommit
}

$pushed = $false
if ($Push -and $strategy -in @('create', 'fast-forward', 'merge')) {
    # Deliberately not a forced update: if another promotion moved the branch after
    # the head above was read, this push is rejected instead of overwriting it.
    $pushOutput = & git '-c' "safe.directory=$safeDirectory" push $Remote "${resultSha}:refs/heads/$Branch" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Unable to advance '$Branch' to '$resultSha'. Another promotion may have moved the branch: $($pushOutput -join ' ')" }
    $pushed = $true
}

$record = [pscustomobject]@{
    schema = 'branch-promotion/v1'
    branch = $Branch
    remote = $Remote
    strategy = $strategy
    approvedSha = $candidateSha
    previousSha = if ($currentSha) { $currentSha } else { $null }
    resultSha = $resultSha
    mergeCommit = $mergeCommit
    pushed = $pushed
    generatedAt = [DateTime]::UtcNow.ToString('o')
}
if (-not $OutputPath) { $OutputPath = "promotion-$Branch.json" }
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$record | ConvertTo-Json -Depth 8
