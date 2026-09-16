<#
    Derives an RC or stable promotion from the persisted release identity.

    The plan always targets the candidate commit recorded in the release manifest,
    never the current head of qa or main. It creates no artifact: the promoted
    version reuses the immutable artifact built during candidate creation.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [Parameter(Mandatory)][string]$ManifestPath,
    [ValidateSet('stable')][string]$TargetChannel = 'stable',
    [string]$OutputPath = 'promotion-plan.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$config = Import-ReleaseConfig $ConfigPath
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.schema -ne 'release-manifest/v2') { throw "'$ManifestPath' is not a v2 release manifest." }

$plan = New-ManifestPromotionPlan -Config $config -Manifest $manifest -TargetChannel $TargetChannel
$plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$plan | ConvertTo-Json -Depth 12
