[CmdletBinding()]
param([string]$MsBuildPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$module = Get-Module ReleasePipeline
$msbuild = & $module {
    param($PreferredPath)
    Find-MSBuild -PreferredPath $PreferredPath -UseVsWhere
} $MsBuildPath
$solution = Join-Path $PSScriptRoot 'tests/fixtures/legacy-dotnet-framework/LegacyFixture.sln'
& $msbuild $solution '/t:Rebuild' '/p:Configuration=Release' '/p:RestorePackages=false' '/m' 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'The legacy .NET Framework MSBuild fixture failed.' }

$output = Join-Path $PSScriptRoot 'tests/fixtures/legacy-dotnet-framework/LegacyFixture/bin/Release/LegacyFixture.exe'
if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "The legacy fixture output was not produced: $output" }
Write-Host "Legacy MSBuild fixture passed with $msbuild."
