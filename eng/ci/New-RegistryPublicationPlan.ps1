[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProvenancePath,
    [string]$ConfigPath = '.releasepipeline.yml',
    [string]$PromotionPlanPath = '',
    [string]$OutputPath = 'registry-publication-plan.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$config = Import-ReleaseConfig $ConfigPath
$provenance = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
$sourceReleases = @($provenance.plan.releases)
$artifacts = @($provenance.artifacts)
$targetReleases = if ($PromotionPlanPath) { @((Get-Content -LiteralPath $PromotionPlanPath -Raw | ConvertFrom-Json).promotions) } else { $sourceReleases }

$publications = foreach ($release in $targetReleases) {
    $component = $config.components[[string]$release.component]
    if (-not $component -or -not $component.ContainsKey('publishing')) { continue }
    $publishing = $component.publishing
    if ($publishing -isnot [System.Collections.IDictionary]) { throw "Publishing configuration for '$($release.component)' must be a mapping." }
    if (-not $publishing.ContainsKey('adapter') -or [string]::IsNullOrWhiteSpace([string]$publishing.adapter)) { throw "Publishing adapter is required for '$($release.component)'." }
    $adapter = [string]$publishing.adapter
    $endpoint = if ($publishing.ContainsKey('endpoint')) { [string]$publishing.endpoint } else { '' }
    $package = if ($publishing.ContainsKey('package')) { [string]$publishing.package } else { $null }
    $image = if ($publishing.ContainsKey('image')) { [string]$publishing.image } else { '' }
    $tokenEnvironmentVariable = if ($publishing.ContainsKey('tokenEnvironmentVariable')) { [string]$publishing.tokenEnvironmentVariable } else { $null }
    if ($adapter -notin @('nuget','npm','container')) { throw "Unsupported registry adapter '$adapter' for '$($release.component)'." }
    $sourceVersion = if ($release.PSObject.Properties.Name -contains 'sourceSemanticVersion') { [string]$release.sourceSemanticVersion } else { [string]$release.semanticVersion }
    $artifact = @($artifacts | Where-Object { $_.component -eq $release.component -and $_.semanticVersion -eq $sourceVersion })
    if ($artifact.Count -ne 1) { throw "Provenance must contain exactly one artifact for '$($release.component)' $($release.semanticVersion)." }
    if ([string]$artifact[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Artifact digest for '$($release.component)' is not a SHA-256 value." }
    if (-not $endpoint -and $adapter -ne 'container') { throw "Publishing endpoint is required for '$($release.component)'." }
    if ($adapter -eq 'container' -and -not $image) { throw "Publishing image is required for '$($release.component)'." }
    $artifactPath = [string]$artifact[0].path
    if ($adapter -ne 'container' -and -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        $artifactName = Split-Path -Leaf $artifactPath
        $localMatches = @(Get-ChildItem -LiteralPath (Split-Path -Parent $ProvenancePath) -Recurse -File -Filter $artifactName -ErrorAction SilentlyContinue)
        if ($localMatches.Count -eq 1) { $artifactPath = $localMatches[0].FullName }
    }
    [pscustomobject]@{
        component = [string]$release.component
        semanticVersion = [string]$release.semanticVersion
        channel = [string]$release.channel
        commit = [string]$release.commit
        adapter = $adapter
        artifactPath = $artifactPath
        sha256 = ([string]$artifact[0].sha256).ToLowerInvariant()
        endpoint = if ($endpoint) { $endpoint } else { $null }
        package = $package
        image = if ($image) { $image } else { $null }
        oidc = if ($publishing.ContainsKey('oidc')) { [bool]$publishing.oidc } else { $true }
        tokenEnvironmentVariable = $tokenEnvironmentVariable
    }
}

$plan = [pscustomobject]@{
    generatedAt = [DateTime]::UtcNow.ToString('o')
    sourceProvenance = (Resolve-Path -LiteralPath $ProvenancePath).Path
    publications = @($publications)
}
$plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$plan | ConvertTo-Json -Depth 16
