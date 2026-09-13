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
    $adapter = [string]$publishing.adapter
    if ($adapter -notin @('nuget','npm','container')) { throw "Unsupported registry adapter '$adapter' for '$($release.component)'." }
    $sourceVersion = if ($release.PSObject.Properties.Name -contains 'sourceSemanticVersion') { [string]$release.sourceSemanticVersion } else { [string]$release.semanticVersion }
    $artifact = @($artifacts | Where-Object { $_.component -eq $release.component -and $_.semanticVersion -eq $sourceVersion })
    if ($artifact.Count -ne 1) { throw "Provenance must contain exactly one artifact for '$($release.component)' $($release.semanticVersion)." }
    if ([string]$artifact[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Artifact digest for '$($release.component)' is not a SHA-256 value." }
    if (-not $publishing.endpoint -and $adapter -ne 'container') { throw "Publishing endpoint is required for '$($release.component)'." }
    if ($adapter -eq 'container' -and -not $publishing.image) { throw "Publishing image is required for '$($release.component)'." }
    [pscustomobject]@{
        component = [string]$release.component
        semanticVersion = [string]$release.semanticVersion
        channel = [string]$release.channel
        commit = [string]$release.commit
        adapter = $adapter
        artifactPath = [string]$artifact[0].path
        sha256 = ([string]$artifact[0].sha256).ToLowerInvariant()
        endpoint = if ($publishing.endpoint) { [string]$publishing.endpoint } else { $null }
        package = if ($publishing.package) { [string]$publishing.package } else { $null }
        image = if ($publishing.image) { [string]$publishing.image } else { $null }
        oidc = if ($publishing.ContainsKey('oidc')) { [bool]$publishing.oidc } else { $true }
        tokenEnvironmentVariable = if ($publishing.tokenEnvironmentVariable) { [string]$publishing.tokenEnvironmentVariable } else { $null }
    }
}

$plan = [pscustomobject]@{
    generatedAt = [DateTime]::UtcNow.ToString('o')
    sourceProvenance = (Resolve-Path -LiteralPath $ProvenancePath).Path
    publications = @($publications)
}
$plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$plan | ConvertTo-Json -Depth 16
