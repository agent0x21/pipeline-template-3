[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [Parameter(Mandatory)][string]$ProvenancePath,
    [Parameter(Mandatory)][ValidateSet('rc','stable')][string]$TargetChannel,
    [string]$OutputPath = 'promotion-plan.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$config = Import-ReleaseConfig $ConfigPath
$plan = New-ArtifactPromotionPlan -Config $config -ProvenancePath $ProvenancePath -TargetChannel $TargetChannel
$plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$plan | ConvertTo-Json -Depth 12
