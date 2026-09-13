[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlanPath, [switch]$Push, [string]$OutputPath = 'promotion-provenance.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$results = foreach ($promotion in @($plan.promotions)) {
    $release = [pscustomobject]@{
        component = $promotion.component
        semanticVersion = $promotion.semanticVersion
        tag = $promotion.tag
        commit = $promotion.commit
    }
    New-ReleaseTag -Release $release -Push:$Push
}
$provenance = [pscustomobject]@{ promotionPlan = $plan; tags = @($results); generatedAt = [DateTime]::UtcNow.ToString('o') }
$provenance | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$provenance | ConvertTo-Json -Depth 16
