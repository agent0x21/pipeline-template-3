<#
    Writes the durable release identity for one release candidate: the exact Git
    SHA, the release/version identifier per component, and the immutable artifact
    digest/checksum that every later stage must consume.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ProvenancePath,
    [string]$RegistryPublicationPath = '',
    [Parameter(Mandatory)][string]$CandidateSha,
    [string]$RunId = $env:GITHUB_RUN_ID,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$OutputPath = 'release-manifest.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$provenance = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
$publication = if ($RegistryPublicationPath) { Get-Content -LiteralPath $RegistryPublicationPath -Raw | ConvertFrom-Json } else { $null }

$manifest = New-ReleaseManifest -Plan $plan -Provenance $provenance -RegistryPublication $publication -CandidateSha $CandidateSha -RunId $RunId -Repository $Repository
$manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$manifest | ConvertTo-Json -Depth 16
