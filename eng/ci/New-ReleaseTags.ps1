param([Parameter(Mandatory)][string]$PlanPath, [switch]$Push)
Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$plan = Get-Content $PlanPath -Raw | ConvertFrom-Json
foreach ($release in $plan.releases) { New-ReleaseTag -Release $release -Push:$Push }
