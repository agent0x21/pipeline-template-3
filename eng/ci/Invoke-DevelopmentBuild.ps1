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
    # Deliberately not named $component: PowerShell variable names are
    # case-insensitive, so a variable here spelled like the -Component parameter
    # above (a [string[]]) would reuse that same, differently-typed variable slot.
    # Assigning this component's hashtable into it would then be silently coerced
    # to a string array instead of failing at the point of assignment, and every
    # property/key access below would fail confusingly far from the real cause.
    $componentConfig = $config.components[$name]
    if ($componentConfig -isnot [System.Collections.IDictionary] -or -not $componentConfig.ContainsKey('path')) {
        $actualType = if ($null -eq $componentConfig) { '<null>' } else { $componentConfig.GetType().FullName }
        throw "Component '$name' in '$ConfigPath' does not have a valid definition (expected a mapping with at least a 'path' property; got $actualType). Check the 'components.$name' entry in the configuration file."
    }
    $build = [pscustomobject]@{
        component = $name
        path = [string]$componentConfig.path
        artifactPath = if ($componentConfig.ContainsKey('package') -and $componentConfig.package.ContainsKey('path')) { [string]$componentConfig.package.path } else { [string]$componentConfig.path }
        componentType = if ($componentConfig.ContainsKey('type')) { [string]$componentConfig.type } else { '' }
        buildCommand = if ($componentConfig.ContainsKey('build') -and $componentConfig.build.ContainsKey('command')) { [string]$componentConfig.build.command } else { '' }
        buildSolution = if ($componentConfig.ContainsKey('build') -and $componentConfig.build.ContainsKey('solution')) { [string]$componentConfig.build.solution } else { '' }
        buildMsbuildPath = if ($componentConfig.ContainsKey('build') -and $componentConfig.build.ContainsKey('msbuildPath')) { [string]$componentConfig.build.msbuildPath } else { '' }
        buildConfiguration = if ($componentConfig.ContainsKey('build') -and $componentConfig.build.ContainsKey('configuration')) { [string]$componentConfig.build.configuration } else { 'Release' }
        testCommand = if ($componentConfig.ContainsKey('test') -and $componentConfig.test.ContainsKey('command')) { [string]$componentConfig.test.command } else { '' }
    }
    Invoke-ComponentBuild -Release $build
    if ($build.testCommand) {
        & pwsh -NoProfile -NonInteractive -Command $build.testCommand 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Tests failed for $name." }
    }
    $archive = Invoke-DevelopmentComponentPackage -Release $build -VersionLabel $versionLabel -OutputDirectory $outputRoot
    $container = Invoke-DevelopmentContainerBuild -Release $build -Component $componentConfig -VersionLabel $versionLabel -CommitSha $candidateSha -Push:$Push
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
