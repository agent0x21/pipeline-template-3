[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ProvenancePath,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Token = $env:GITHUB_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Repository)) { throw 'Repository is required. Set GITHUB_REPOSITORY or pass -Repository.' }
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'Token is required. Set GITHUB_TOKEN or pass -Token.' }

function Resolve-DownloadedArtifactPath {
    param([Parameter(Mandatory)][string]$RecordedPath, [Parameter(Mandatory)][string]$SourceProvenancePath)
    if (Test-Path -LiteralPath $RecordedPath -PathType Leaf) { return (Resolve-Path -LiteralPath $RecordedPath).Path }
    $name = Split-Path -Leaf $RecordedPath
    $matches = @(Get-ChildItem -LiteralPath (Split-Path -Parent $SourceProvenancePath) -Recurse -File -Filter $name -ErrorAction SilentlyContinue)
    if ($matches.Count -ne 1) { throw "Could not resolve the immutable artifact '$RecordedPath' beside '$SourceProvenancePath'." }
    return $matches[0].FullName
}

function Publish-GitHubReleaseAsset {
    param(
        [Parameter(Mandatory)]$GitHubRelease,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ContentType
    )
    $existing = @($GitHubRelease.assets | Where-Object { $_.name -eq $Name })
    if ($existing.Count -gt 1) { throw "GitHub release '$($GitHubRelease.tag_name)' contains multiple assets named '$Name'." }
    if ($existing.Count -eq 1) {
        if ([string]$existing[0].digest -eq "sha256:$Sha256") {
            Write-Host "GitHub release asset already exists for $($GitHubRelease.tag_name): $Name"
            return
        }
        throw "GitHub release asset '$Name' already exists for '$($GitHubRelease.tag_name)' with a different or unavailable SHA-256 digest."
    }
    $uploadUri = "https://uploads.github.com/repos/$Repository/releases/$($GitHubRelease.id)/assets?name=$([uri]::EscapeDataString($Name))&label=$([uri]::EscapeDataString($Label))"
    Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $Headers -ContentType $ContentType -InFile $Path | Out-Null
    Write-Host "Uploaded GitHub release asset for $($GitHubRelease.tag_name): $Name"
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$provenance = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
$releases = @($plan.releases)
if ($releases.Count -eq 0 -and $plan.PSObject.Properties.Name -contains 'promotions') { $releases = @($plan.promotions) }
if ($releases.Count -eq 0) { Write-Host 'The release plan is empty; no GitHub release assets will be uploaded.'; return }

$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "Bearer $Token"; 'X-GitHub-Api-Version' = '2022-11-28' }
$releaseBaseUri = "https://api.github.com/repos/$Repository/releases"
foreach ($release in $releases) {
    $sourceVersion = if ($release.PSObject.Properties.Name -contains 'sourceSemanticVersion') { [string]$release.sourceSemanticVersion } else { [string]$release.semanticVersion }
    $artifacts = @($provenance.artifacts | Where-Object { $_.component -eq $release.component -and $_.semanticVersion -eq $sourceVersion })
    if ($artifacts.Count -eq 0) { throw "Provenance does not contain artifacts for '$($release.component)' version '$sourceVersion'." }

    $tagUri = [uri]::EscapeDataString([string]$release.tag)
    try {
        $githubRelease = Invoke-RestMethod -Method Get -Uri "$releaseBaseUri/tags/$tagUri" -Headers $headers
    } catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 404) { throw "GitHub release metadata for '$($release.tag)' does not exist. Publish metadata before uploading assets." }
        throw
    }

    $releaseArtifacts = foreach ($artifact in $artifacts) {
        $expectedHash = ([string]$artifact.sha256).ToLowerInvariant()
        if ($expectedHash -notmatch '^[a-f0-9]{64}$') { throw "Artifact digest for '$($release.component)' is not a SHA-256 value." }
        $artifactPath = Resolve-DownloadedArtifactPath -RecordedPath ([string]$artifact.path) -SourceProvenancePath $ProvenancePath
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw "Artifact digest mismatch for '$artifactPath'. Expected $expectedHash, got $actualHash." }
        $artifactType = if ($artifact.PSObject.Properties.Name -contains 'artifactType') { [string]$artifact.artifactType } else { 'zip' }
        $suffix = if ($artifactType -eq 'container-image') { '.container.tar' } elseif ($artifactType -eq 'zip') { '.zip' } else { throw "Unsupported GitHub release artifact type '$artifactType'." }
        $assetName = "$($release.component)-v$($release.semanticVersion)$suffix"
        Publish-GitHubReleaseAsset -GitHubRelease $githubRelease -Name $assetName -Path $artifactPath -Sha256 $expectedHash -Headers $headers -Repository $Repository -Label "$($release.component) $artifactType" -ContentType 'application/octet-stream'
        [pscustomobject]@{ path = $assetName; sha256 = $expectedHash; component = $release.component; semanticVersion = $release.semanticVersion; artifactType = $artifactType }
    }
    $releaseProvenance = [pscustomobject]@{ plan = [pscustomobject]@{ releases = @($release) }; artifacts = @($releaseArtifacts) }
    $provenanceAsset = "$($release.component)-v$($release.semanticVersion).provenance.json"
    $provenancePath = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString('N')).json"
    try {
        $releaseProvenance | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $provenancePath -Encoding utf8
        $provenanceHash = (Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Publish-GitHubReleaseAsset -GitHubRelease $githubRelease -Name $provenanceAsset -Path $provenancePath -Sha256 $provenanceHash -Headers $headers -Repository $Repository -Label "$($release.component) release provenance" -ContentType 'application/json'
    } finally {
        Remove-Item -LiteralPath $provenancePath -Force -ErrorAction SilentlyContinue
    }
}
