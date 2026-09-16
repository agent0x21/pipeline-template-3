[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('PrepareQA','ApproveQA','PromotePROD')][string]$Operation,
    [Parameter(Mandatory)][ValidatePattern('^release/[A-Za-z0-9._-]+$')][string]$ReleaseId,
    [string]$ExpectedManifestSha256 = '', [string]$QaRunId = '',
    [string]$ConfigPath = '.releasepipeline.yml', [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$OutputDirectory = '.release-handoff'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ciRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$ciRoot/ReleasePipeline/ReleasePipeline.psd1" -Force
. "$ciRoot/ReleasePipeline/ArtifactHandoff.ps1"
. "$PSScriptRoot/ReleaseStore.ps1"
if ($Repository -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Invalid repository.' }
$release = Get-StoredRelease $ReleaseId
if ($release.draft) { throw 'Release publication is incomplete. Resume its build workflow.' }
$manifestPath = Get-StoredAsset $release 'release-manifest.json' $OutputDirectory
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
Assert-ReleaseManifestV2 $manifest -Repository $Repository
if ($manifest.releaseId -ne $ReleaseId) { throw 'Release identifier mismatch.' }
Assert-StoredTagCommit $ReleaseId $manifest.candidateSha
foreach ($component in $manifest.components) { Assert-StoredTagCommit $component.tag $manifest.candidateSha }
$hash = (Get-FileHash $manifestPath).Hash.ToLowerInvariant()
if ($ExpectedManifestSha256 -and $hash -ne $ExpectedManifestSha256) { throw 'Manifest changed since preparation.' }
foreach ($component in $manifest.components) { Get-StoredAsset $release $component.archiveAsset $OutputDirectory | Out-Null }
Test-HandoffArtifacts $manifest $OutputDirectory -VerifyContainers
$environment = if ($Operation -eq 'PromotePROD') { 'PROD' } else { 'QA' }
$handoff = New-ArtifactHandoff $manifest $hash $environment ([IO.Path]::GetFullPath($OutputDirectory))
Save-ReleaseJson $handoff "$OutputDirectory/handoff.json"
if ($env:GITHUB_OUTPUT) { "manifest_sha256=$hash" | Add-Content $env:GITHUB_OUTPUT }
if ($Operation -eq 'ApproveQA') {
    if (-not $ExpectedManifestSha256) { throw 'QA sign-off requires the checksum captured before manual testing.' }
    $review = Get-EnvironmentReview QA
    $name = "qa-signoff-$($env:GITHUB_RUN_ID).json"
    $existingPath = Get-StoredAsset $release $name $OutputDirectory -Optional
    if ($existingPath) {
        Assert-QaSignoff $manifest $hash (Get-Content $existingPath -Raw | ConvertFrom-Json)
    } else {
        $approval = [pscustomobject]@{
            schema = 'qa-signoff/v2'; status = 'QA-approved'; environment = 'QA'
            releaseId = $ReleaseId; candidateSha = $manifest.candidateSha; manifestSha256 = $hash
            reviewers = $review.reviewers; evidenceUrl = $review.evidenceUrl; runId = $review.runId
            approvedAt = [DateTime]::UtcNow.ToString('o')
            attestation = 'The reviewer confirms manual installation and testing of every artifact in this manifest.'
        }
        Save-ReleaseJson $approval "$OutputDirectory/$name"
        Add-StoredAsset $release "$OutputDirectory/$name"
    }
}
if ($Operation -eq 'PromotePROD') {
    if ($QaRunId -notmatch '^\d+$') { throw 'A QA sign-off workflow run ID is required.' }
    $approvalPath = Get-StoredAsset $release "qa-signoff-$QaRunId.json" $OutputDirectory
    $approval = Get-Content $approvalPath -Raw | ConvertFrom-Json
    Assert-QaSignoff $manifest $hash $approval
    if ($approval.runId -ne $QaRunId) { throw 'QA approval run identity mismatch.' }
    $qaRun = Invoke-ReleaseApi "actions/runs/$QaRunId"
    if ($qaRun.path -ne '.github/workflows/prepare-qa.yml' -or $qaRun.head_branch -ne 'main' -or $qaRun.conclusion -ne 'success') { throw 'QA evidence must originate from a successful Prepare QA workflow on main.' }
    $qaReview = Get-EnvironmentReview QA -RunId $QaRunId
    if (@(Compare-Object @($approval.reviewers) @($qaReview.reviewers)).Count) { throw 'QA reviewer evidence differs from the stored sign-off.' }
    $review = Get-EnvironmentReview PROD
    $config = Import-ReleaseConfig $ConfigPath
    $plan = New-ManifestPromotionPlan -Config $config -Manifest $manifest
    $planPath = "$OutputDirectory/promotion-plan.json"
    Save-ReleaseJson $plan $planPath
    # Bind each stable tag to one RC manifest before any tag/asset is promoted.
    foreach ($entry in $plan.promotions) {
        $stable = Get-StoredRelease $entry.tag -AllowMissing
        if ($stable) {
            $identity = Get-StoredAsset $stable 'source-release-manifest.json' "$OutputDirectory/$($entry.component)" -Optional
            if (-not $identity -and $stable.draft) {
                $reservation = $stable.body | ConvertFrom-Json
                if ($reservation.manifestSha256 -ne $hash -or $reservation.releaseId -ne $ReleaseId) { throw 'Stable release reservation belongs to another RC.' }
                Add-StoredAsset $stable $manifestPath 'source-release-manifest.json'
                $identity = $manifestPath
            }
            if (-not $identity -or (Get-FileHash $identity).Hash.ToLowerInvariant() -ne $hash) { throw "Stable release '$($entry.tag)' belongs to another RC or has incomplete identity. Recover it before proceeding." }
        } else {
            $reservation = @{ releaseId = $ReleaseId; manifestSha256 = $hash; installed = $false } | ConvertTo-Json -Compress
            $stable = Invoke-ReleaseApi -Path 'releases' -Method POST -Body @{ tag_name = $entry.tag; target_commitish = $manifest.candidateSha; draft = $true; name = "$($entry.component) v$($entry.semanticVersion)"; body = $reservation }
            Add-StoredAsset $stable $manifestPath 'source-release-manifest.json'
        }
        New-ReleaseTag -Release $entry -Push | Out-Null
        $source = @($manifest.components | Where-Object component -eq $entry.component)[0]
        Add-StoredAsset $stable (Join-Path $OutputDirectory $source.archiveAsset) "$($entry.component)-v$($entry.semanticVersion).zip"
    }
    & "$ciRoot/Publish-PromotedImageTag.ps1" -ManifestPath $manifestPath -PromotionPlanPath $planPath -OutputPath "$OutputDirectory/promoted-image-tags.json"
    foreach ($entry in $plan.promotions) {
        $stable = Get-StoredRelease $entry.tag
        Invoke-ReleaseApi -Path "releases/$($stable.id)" -Method PATCH -Body @{ draft = $false; prerelease = $false; make_latest = 'false' } | Out-Null
    }
    $recordName = "production-approval-$($env:GITHUB_RUN_ID).json"
    if (-not (Get-StoredAsset $release $recordName $OutputDirectory -Optional)) {
        Save-ReleaseJson ([pscustomobject]@{
            schema = 'production-approval/v2'; status = 'production release approved'; installed = $false
            environment = 'PROD'; releaseId = $ReleaseId; candidateSha = $manifest.candidateSha
            manifestSha256 = $hash; qaRunId = $QaRunId; reviewers = $review.reviewers; evidenceUrl = $review.evidenceUrl
            approvedAt = [DateTime]::UtcNow.ToString('o'); promotions = $plan.promotions
        }) "$OutputDirectory/$recordName"
        Add-StoredAsset $release "$OutputDirectory/$recordName"
    }
}
if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "## $environment manual artifact handoff"
        "Release: [$ReleaseId](https://github.com/$Repository/releases/tag/$ReleaseId)"
        "Source: $($manifest.candidateSha)"
        "Manifest SHA-256: $hash"
        'No installation was performed. Download and verify the ZIPs or pull the images by digest; supply runtime configuration separately.'
        ''
        '| Component | RC build version | ZIP SHA-256 | Container digest |'
        '| --- | --- | --- | --- |'
        @($manifest.components | ForEach-Object { "| $($_.component) | $($_.semanticVersion) | $($_.archiveSha256) | $($_.imageDigest) |" })
        ''
        $(if ($Operation -eq 'PrepareQA') { 'After installing and testing ALL listed artifacts, approve the waiting QA job. Approval attests to this exact manifest.' } else { "Completed: $Operation. QA run identifier for promotion: $($env:GITHUB_RUN_ID)." })
    ) | Add-Content $env:GITHUB_STEP_SUMMARY
}
