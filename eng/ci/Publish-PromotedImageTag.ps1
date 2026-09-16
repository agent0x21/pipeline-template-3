<#
    Publishes the promoted RC/stable version tag for an already-built image.

    The image is resolved by its immutable manifest digest and re-tagged. Nothing
    is compiled, packaged, or rebuilt, and the digest is re-read after the push: if
    the promoted tag does not resolve to the same digest the release fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$PromotionPlanPath,
    [string]$OutputPath = 'promoted-image-tags.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.schema -ne 'release-manifest/v2') { throw "'$ManifestPath' is not a v2 release manifest." }
$promotions = @((Get-Content -LiteralPath $PromotionPlanPath -Raw | ConvertFrom-Json).promotions)
if (@($manifest.components | Where-Object imageDigest).Count -gt 0 -and -not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker is required to publish a promoted image tag.' }

$results = foreach ($promotion in $promotions) {
    $name = [string]$promotion.component
    $component = @($manifest.components | Where-Object { $_.component -eq $name })
    if ($component.Count -ne 1) { throw "The release manifest does not contain exactly one entry for '$name'." }
    $digest = [string]$component[0].imageDigest
    if (-not $digest) { continue }
    if ([string]$component[0].semanticVersion -ne [string]$promotion.sourceSemanticVersion) {
        throw "Promotion source version '$($promotion.sourceSemanticVersion)' for '$name' does not match the released version '$($component[0].semanticVersion)'."
    }
    $image = [string]$component[0].image
    $reference = "$image@$digest"
    & docker pull $reference 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "The registry does not serve '$reference'." }

    $promotedTag = [string]$promotion.semanticVersion
    $target = "${image}:$promotedTag"
    $existing = & docker pull $target 2>&1
    if ($LASTEXITCODE -eq 0) {
        if ((Get-PushedImageDigest -Image $image -Tag $promotedTag) -ne $digest) { throw "Immutable image tag '$target' already identifies another artifact." }
    } elseif (($existing -join ' ') -notmatch 'manifest unknown|not found|manifest.*unknown') {
        throw "Cannot check existing image tag '$target': $($existing -join ' ')"
    }
    & docker tag $reference $target 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Unable to tag '$target'." }
    & docker push $target 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Unable to push '$target'." }

    $publishedDigest = Get-PushedImageDigest -Image $image -Tag $promotedTag
    if ($publishedDigest -ne $digest) {
        throw "Promoted tag '$target' resolves to '$publishedDigest' instead of the released digest '$digest'. The promoted artifact is not the artifact QA validated."
    }
    [pscustomobject]@{ component = $name; image = $image; promotedTag = $promotedTag; sourceSemanticVersion = [string]$promotion.sourceSemanticVersion; imageDigest = $digest }
}

$record = [pscustomobject]@{
    schema = 'promoted-image-tags/v1'
    releaseId = [string]$manifest.releaseId
    candidateSha = [string]$manifest.candidateSha
    rebuilt = $false
    generatedAt = [DateTime]::UtcNow.ToString('o')
    tags = @($results)
}
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$record | ConvertTo-Json -Depth 12
