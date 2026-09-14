<#
    Production guardrail: fail if the job that is about to deploy has produced any
    application build output.

    A production job checks out a clean tree and only resolves an already-published
    digest, so the configured package/build output paths must not exist. If they do,
    something compiled, packaged, or repackaged the application in this job and the
    release is no longer provably the artifact QA approved.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [string[]]$AdditionalPath = @('release-plan.json', 'artifacts')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$config = Import-ReleaseConfig $ConfigPath
$suspect = [Collections.Generic.List[string]]::new()

foreach ($name in $config.components.Keys) {
    $component = $config.components[$name]
    if ($component.ContainsKey('package') -and $component.package -is [System.Collections.IDictionary] -and $component.package.ContainsKey('path')) {
        $packagePath = [string]$component.package.path
        if ($packagePath -and (Test-Path -LiteralPath $packagePath)) { $suspect.Add("$name -> $packagePath") }
    }
}
foreach ($path in $AdditionalPath) {
    if ($path -and (Test-Path -LiteralPath $path)) { $suspect.Add($path) }
}

if ($suspect.Count -gt 0) {
    throw "Production must never rebuild the application, but build output is present in this job: $($suspect -join ', '). Deploy the immutable artifact digest recorded in the release manifest instead."
}

Write-Host 'Verified: no application build, package, or publish output exists in this deployment job.'
