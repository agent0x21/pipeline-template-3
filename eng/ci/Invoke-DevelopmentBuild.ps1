<#
    Builds a development artifact for one branch at one exact commit.

    A development artifact is explicitly requested by a developer, is keyed by
    branch and Git SHA rather than by SemVer, creates no Git tags, and is never a
    release candidate. Nothing here writes a release plan or a promotion plan, so
    a development artifact cannot be fed into the QA -> production promotion path.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [Parameter(Mandatory)][string]$ExpectedSha,
    [Parameter(Mandatory)][string]$Branch,
    [string[]]$Component = @(),
    [string]$OutputDirectory = 'dev-artifacts',
    [switch]$Push,
    [string]$OutputPath = 'development-build.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$config = Import-ReleaseConfig $ConfigPath
$candidateSha = Assert-CandidateCommit -ExpectedSha $ExpectedSha
$shortSha = Get-ShortSha $candidateSha
$versionLabel = "dev-$shortSha"

$requested = if ($Component.Count -gt 0) { @($Component) } else { @($config.components.Keys) }
foreach ($name in $requested) {
    if (-not $config.components.ContainsKey($name)) { throw "Unknown component '$name'. Configured components: $(@($config.components.Keys) -join ', ')." }
}

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$results = foreach ($name in $requested) {
    $component = $config.components[$name]
    $build = [pscustomobject]@{
        component = $name
        path = [string]$component.path
        artifactPath = if ($component.ContainsKey('package') -and $component.package.ContainsKey('path')) { [string]$component.package.path } else { [string]$component.path }
        componentType = if ($component.ContainsKey('type')) { [string]$component.type } else { '' }
        buildCommand = if ($component.ContainsKey('build') -and $component.build.ContainsKey('command')) { [string]$component.build.command } else { '' }
        buildSolution = if ($component.ContainsKey('build') -and $component.build.ContainsKey('solution')) { [string]$component.build.solution } else { '' }
        buildMsbuildPath = if ($component.ContainsKey('build') -and $component.build.ContainsKey('msbuildPath')) { [string]$component.build.msbuildPath } else { '' }
        buildConfiguration = if ($component.ContainsKey('build') -and $component.build.ContainsKey('configuration')) { [string]$component.build.configuration } else { 'Release' }
        testCommand = if ($component.ContainsKey('test') -and $component.test.ContainsKey('command')) { [string]$component.test.command } else { '' }
    }
    Invoke-ComponentBuild -Release $build
    if ($build.testCommand) {
        & pwsh -NoProfile -NonInteractive -Command $build.testCommand 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Tests failed for $name." }
    }
    $archive = Invoke-DevelopmentComponentPackage -Release $build -VersionLabel $versionLabel -OutputDirectory $outputRoot
    $container = Invoke-DevelopmentContainerBuild -Release $build -Component $component -VersionLabel $versionLabel -CommitSha $candidateSha -Push:$Push
    [pscustomobject]@{
        component = $name
        versionLabel = $versionLabel
        archivePath = [string]$archive.path
        archiveSha256 = [string]$archive.sha256
        image = if ($container) { [string]$container.image } else { $null }
        imageReference = if ($container) { [string]$container.tag } else { $null }
        imageDigest = if ($container -and $container.digest) { [string]$container.digest } else { $null }
    }
}

$record = [pscustomobject]@{
    schema = 'development-build/v1'
    isReleaseCandidate = $false
    sourceBranch = $Branch
    gitSha = $candidateSha
    shortSha = $shortSha
    versionLabel = $versionLabel
    pushed = [bool]$Push
    generatedAt = [DateTime]::UtcNow.ToString('o')
    components = @($results)
}
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$record | ConvertTo-Json -Depth 12
