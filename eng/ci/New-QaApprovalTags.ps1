<#
    Creates immutable qa-approved/* markers on the exact QA-approved commit.

    These are independent Git refs, not commits on a branch. New-ReleaseTag is
    idempotent when the marker already points at the approved commit and fails
    safely if an existing marker would have to be moved.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApprovedManifestPath,
    [switch]$Push,
    [string]$OutputPath = 'qa-approval-tags.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$manifest = Get-Content -LiteralPath $ApprovedManifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.schema -ne 'release-manifest/v1') { throw "'$ApprovedManifestPath' is not a release manifest." }
$candidateSha = [string]$manifest.candidateSha

$results = foreach ($component in @($manifest.components)) {
    $release = [pscustomobject]@{
        component = [string]$component.component
        semanticVersion = [string]$component.semanticVersion
        tag = "qa-approved/$([string]$component.tag)"
        commit = $candidateSha
    }
    New-ReleaseTag -Release $release -Push:$Push
}

$record = [pscustomobject]@{
    schema = 'qa-approval-tags/v1'
    releaseId = [string]$manifest.releaseId
    candidateSha = $candidateSha
    tags = @($results)
    generatedAt = [DateTime]::UtcNow.ToString('o')
}
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$record | ConvertTo-Json -Depth 12
