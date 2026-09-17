[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [switch]$SetupOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$config = Import-ReleaseConfig $ConfigPath

function Invoke-ValidationCommand {
    param([Parameter(Mandatory)][string]$Description, [string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return }
    Write-Host "Running $Description from '$ConfigPath'."
    & pwsh -NoProfile -NonInteractive -Command $Command 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Description failed." }
}

$setupCommand = if ($config.ContainsKey('validation') -and $config.validation.ContainsKey('setup')) {
    [string]$config.validation.setup.command
} else {
    ''
}
Invoke-ValidationCommand -Description 'validation setup' -Command $setupCommand

if ($SetupOnly) { return }

foreach ($name in @($config.components.Keys | Sort-Object)) {
    $component = $config.components[$name]
    $testCommand = if ($component.ContainsKey('test') -and $component.test.ContainsKey('command')) { [string]$component.test.command } else { '' }
    $buildCommand = if ($component.ContainsKey('validation') -and $component.validation.ContainsKey('command')) {
        [string]$component.validation.command
    } elseif ($component.ContainsKey('build') -and $component.build.ContainsKey('command')) {
        [string]$component.build.command
    } else {
        ''
    }
    Invoke-ValidationCommand -Description "tests for component '$name'" -Command $testCommand
    Invoke-ValidationCommand -Description "build for component '$name'" -Command $buildCommand
}
