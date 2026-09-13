param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [ValidateSet('major','minor','patch')][string]$VersionBump,
    [string]$ComponentOverridesJson = '{}', [string]$ExactVersionsJson = '{}',
    [string]$Branch = $(git -c "safe.directory=$((Get-Location).Path)" branch --show-current), [string]$BaseRef = 'HEAD~1',
    [string]$CiRunId = $env:GITHUB_RUN_ID, [string]$OutputPath = 'release-plan.json', [switch]$ReleaseAll
)
Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$config = Import-ReleaseConfig $ConfigPath
$planArguments = @{ Config = $config; ComponentOverrides = ($ComponentOverridesJson | ConvertFrom-Json -AsHashtable); ExactVersions = ($ExactVersionsJson | ConvertFrom-Json -AsHashtable); Branch = $Branch; BaseRef = $BaseRef; CiRunId = $CiRunId; Repository = $env:GITHUB_REPOSITORY }
if ($VersionBump) { $planArguments.VersionBump = $VersionBump }
if ($ReleaseAll) { $planArguments.ReleaseAll = $true }
$plan = New-ReleasePlan @planArguments
$plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$plan | ConvertTo-Json -Depth 12
