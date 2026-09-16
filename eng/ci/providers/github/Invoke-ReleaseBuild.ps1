[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [Parameter(Mandatory)][string]$ExpectedSha,
    [string]$SourceRef = 'main', [string]$BaselineRelease = '',
    [ValidateSet('minor','major','patch')][string]$VersionBump = 'minor',
    [string]$ComponentOverridesJson = '{}', [string]$ExactVersionsJson = '{}', [switch]$ReleaseAll,
    [string]$Repository = $env:GITHUB_REPOSITORY, [string]$RunId = $env:GITHUB_RUN_ID
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ciRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$ciRoot/ReleasePipeline/ReleasePipeline.psd1" -Force
. "$ciRoot/ReleasePipeline/ArtifactHandoff.ps1"
. "$PSScriptRoot/ReleaseStore.ps1"
if ($Repository -notmatch '^[\w.-]+/[\w.-]+$' -or $RunId -notmatch '^\d+$') { throw 'Repository and numeric CI run ID are required.' }
$config = Import-ReleaseConfig $ConfigPath
Assert-CandidateCommit -ExpectedSha $ExpectedSha | Out-Null
$releaseId = "release/$RunId"
$release = Get-StoredRelease $releaseId -AllowMissing
$work = Join-Path (Get-Location) '.release-work'
New-Item -ItemType Directory -Force $work | Out-Null
$planPath = Join-Path $work 'release-plan.json'
if ($release) {
    if (-not (Get-StoredAsset $release 'release-plan.json' $work -Optional)) {
        Save-ReleaseJson ($release.body | ConvertFrom-Json) $planPath
        Add-StoredAsset $release $planPath
    }
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json
    if ($plan.commit -ne $ExpectedSha) { throw 'Retry source differs from the persisted release plan. Use the original SHA.' }
    if ($plan.configSha256 -ne (Get-FileHash $ConfigPath).Hash.ToLowerInvariant()) { throw 'Retry requires the original release configuration.' }
} else {
    $plan = New-ReleasePlan -Config $config -Branch $SourceRef -Commit $ExpectedSha -VersionBump $VersionBump -ComponentOverrides ($ComponentOverridesJson | ConvertFrom-Json -AsHashtable) -ExactVersions ($ExactVersionsJson | ConvertFrom-Json -AsHashtable) -ReleaseAll:$ReleaseAll -CiRunId $RunId -Repository $Repository
    if (@($plan.releases).Count -eq 0) { throw 'No affected components. Use release_all only when a full release is intended.' }
    if (@($plan.releases | Where-Object bumpSource -eq 'rerun').Count) { throw 'This commit already has an RC. Resume its original run or select its existing release; do not rebuild it.' }
    $plan | Add-Member baselineRelease $BaselineRelease
    $plan | Add-Member orchestratorSha $env:GITHUB_SHA
    $plan | Add-Member configSha256 (Get-FileHash $ConfigPath).Hash.ToLowerInvariant()
    Save-ReleaseJson $plan $planPath
    New-ReleaseTag -Release ([pscustomobject]@{ tag = $releaseId; commit = $ExpectedSha; component = 'release-set'; semanticVersion = $RunId }) -Push | Out-Null
    # The draft body is a backup plan if uploading the plan asset is interrupted.
    $release = Invoke-ReleaseApi -Path 'releases' -Method POST -Body @{ tag_name = $releaseId; target_commitish = $ExpectedSha; name = $releaseId; draft = $true; prerelease = $true; body = ($plan | ConvertTo-Json -Depth 30) }
    Add-StoredAsset $release $planPath
}
# Reserve versions before building so a failed run cannot lose its version to another run.
foreach ($entry in $plan.releases) { New-ReleaseTag -Release $entry -Push | Out-Null }
# A durable staging bundle is written before component assets are published.
# Full workflow reruns reuse it, including after partial registry publication.
$bundle = Get-StoredAsset $release 'build-bundle.zip' $work -Optional
if ($bundle) {
    Expand-Archive -LiteralPath $bundle -DestinationPath $work -Force
} else {
    & "$ciRoot/Invoke-ReleasePackage.ps1" -PlanPath $planPath -ConfigPath $ConfigPath -OutputDirectory "$work/artifacts"
    Compress-Archive -Path "$work/artifacts" -DestinationPath "$work/build-bundle.zip" -Force
    Add-StoredAsset $release "$work/build-bundle.zip"
}
$provenancePath = "$work/artifacts/provenance.json"
$provenance = Get-Content $provenancePath -Raw | ConvertFrom-Json
# Rebase recorded local paths after restoring the bundle on a different runner.
foreach ($artifact in $provenance.artifacts) {
    $matches = @(Get-ChildItem "$work/artifacts" -Recurse -File | Where-Object Name -eq (Split-Path -Leaf $artifact.path))
    if ($matches.Count -ne 1 -or (Get-FileHash $matches[0].FullName).Hash.ToLowerInvariant() -ne $artifact.sha256) { throw 'Staged artifact is missing or has changed.' }
    $artifact.path = $matches[0].FullName
}
Save-ReleaseJson $provenance $provenancePath
$manifestPath = Get-StoredAsset $release 'release-manifest.json' $work -Optional
if (-not $manifestPath) {
    & "$ciRoot/New-RegistryPublicationPlan.ps1" -ConfigPath $ConfigPath -ProvenancePath $provenancePath -OutputPath "$work/registry-plan.json"
    & "$ciRoot/Publish-RegistryArtifacts.ps1" -PlanPath "$work/registry-plan.json" -OutputPath "$work/registry-publication.json"
    $publication = Get-Content "$work/registry-publication.json" -Raw | ConvertFrom-Json
    $manifest = New-ReleaseManifest -Plan $plan -Provenance $provenance -RegistryPublication $publication -CandidateSha $ExpectedSha -Repository $Repository -RunId $RunId
    $manifest.schema = 'release-manifest/v2'; $manifest.releaseId = $releaseId
    $manifest | Add-Member baselineRelease $plan.baselineRelease
    $manifest | Add-Member orchestratorSha $plan.orchestratorSha
    $manifest | Add-Member configSha256 $plan.configSha256
    foreach ($component in $manifest.components) { $component | Add-Member archiveAsset "$($component.component)-v$($component.semanticVersion).zip" }
    $manifestPath = "$work/release-manifest.json"
    Save-ReleaseJson $manifest $manifestPath
    Add-StoredAsset $release $manifestPath
}
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
Assert-ReleaseManifestV2 $manifest -Repository $Repository
if ($manifest.releaseId -ne $releaseId -or $manifest.candidateSha -ne $ExpectedSha -or @($manifest.components).Count -ne @($plan.releases).Count) { throw 'Persisted release manifest does not match the build plan.' }
foreach ($component in $manifest.components) {
    $archive = @($provenance.artifacts | Where-Object { $_.artifactType -eq 'zip' -and $_.component -eq $component.component -and $_.semanticVersion -eq $component.semanticVersion })
    if ($archive.Count -ne 1 -or $archive[0].sha256 -ne $component.archiveSha256) { throw 'Persisted release manifest does not match the staged ZIP.' }
}
foreach ($entry in $plan.releases) { New-ReleaseTag -Release $entry -Push | Out-Null }
& "$PSScriptRoot/Publish-GitHubReleaseMetadata.ps1" -PlanPath $planPath -Repository $Repository -Token $env:GH_TOKEN
& "$PSScriptRoot/Publish-GitHubReleaseAssets.ps1" -PlanPath $planPath -ProvenancePath $provenancePath -Repository $Repository -Token $env:GH_TOKEN
foreach ($artifact in $provenance.artifacts | Where-Object artifactType -eq 'zip') { Add-StoredAsset $release $artifact.path }
Invoke-ReleaseApi -Path "releases/$($release.id)" -Method PATCH -Body @{ draft = $false; prerelease = $true; make_latest = 'false' } | Out-Null
if ($env:GITHUB_STEP_SUMMARY) { "## RC artifacts ready for manual QA`n`nRelease: [$releaseId](https://github.com/$Repository/releases/tag/$releaseId)`n`nSource: $ExpectedSha`n`nRun Prepare QA with this release identifier. Nothing has been installed." | Add-Content $env:GITHUB_STEP_SUMMARY }
