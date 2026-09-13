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

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$provenance = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
$releases = @($plan.releases)
if ($releases.Count -eq 0 -and $plan.PSObject.Properties.Name -contains 'promotions') { $releases = @($plan.promotions) }
if ($releases.Count -eq 0) { Write-Host 'The release plan is empty; no GitHub release assets will be uploaded.'; return }

$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "Bearer $Token"; 'X-GitHub-Api-Version' = '2022-11-28' }
$releaseBaseUri = "https://api.github.com/repos/$Repository/releases"
foreach ($release in $releases) {
    $sourceVersion = if ($release.PSObject.Properties.Name -contains 'sourceSemanticVersion') { [string]$release.sourceSemanticVersion } else { [string]$release.semanticVersion }
    $artifact = @($provenance.artifacts | Where-Object {
        $_.component -eq $release.component -and $_.semanticVersion -eq $sourceVersion -and
        (($_.PSObject.Properties.Name -notcontains 'artifactType') -or $_.artifactType -eq 'zip')
    })
    if ($artifact.Count -ne 1) { throw "Provenance must contain exactly one artifact for '$($release.component)' version '$sourceVersion'." }
    $expectedHash = ([string]$artifact[0].sha256).ToLowerInvariant()
    if ($expectedHash -notmatch '^[a-f0-9]{64}$') { throw "Artifact digest for '$($release.component)' is not a SHA-256 value." }
    $artifactPath = Resolve-DownloadedArtifactPath -RecordedPath ([string]$artifact[0].path) -SourceProvenancePath $ProvenancePath
    $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "Artifact digest mismatch for '$artifactPath'. Expected $expectedHash, got $actualHash." }

    $tagUri = [uri]::EscapeDataString([string]$release.tag)
    try {
        $githubRelease = Invoke-RestMethod -Method Get -Uri "$releaseBaseUri/tags/$tagUri" -Headers $headers
    } catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 404) { throw "GitHub release metadata for '$($release.tag)' does not exist. Publish metadata before uploading assets." }
        throw
    }

    $assetName = "$($release.component)-v$($release.semanticVersion).zip"
    $existing = @($githubRelease.assets | Where-Object { $_.name -eq $assetName })
    if ($existing.Count -gt 1) { throw "GitHub release '$($release.tag)' contains multiple assets named '$assetName'." }
    if ($existing.Count -eq 1) {
        $existingDigest = [string]$existing[0].digest
        if ($existingDigest -eq "sha256:$expectedHash") {
            Write-Host "GitHub release asset already exists for $($release.tag): $assetName"
            continue
        }
        throw "GitHub release asset '$assetName' already exists for '$($release.tag)' with a different or unavailable SHA-256 digest."
    }

    $uploadUri = "https://uploads.github.com/repos/$Repository/releases/$($githubRelease.id)/assets?name=$([uri]::EscapeDataString($assetName))&label=$([uri]::EscapeDataString("$($release.component) deployable ZIP"))"
    Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $headers -ContentType 'application/zip' -InFile $artifactPath | Out-Null
    Write-Host "Uploaded GitHub release asset for $($release.tag): $assetName"
}
