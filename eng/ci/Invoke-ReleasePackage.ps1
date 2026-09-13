param([Parameter(Mandatory)][string]$PlanPath, [string]$ConfigPath = '.releasepipeline.yml', [string]$OutputDirectory = 'artifacts')
Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$plan = Get-Content $PlanPath -Raw | ConvertFrom-Json
$config = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { Import-ReleaseConfig $ConfigPath } else { $null }
$repoRoot = (Get-Location).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$releases = @($plan.releases)
if ($releases.Count -eq 0) {
    $provenance = [pscustomobject]@{ plan = $plan; artifacts = @(); generatedAt = [DateTime]::UtcNow.ToString('o') }
    $provenance | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $outputRoot 'provenance.json') -Encoding utf8
    $provenance | ConvertTo-Json -Depth 20
    return
}
$packages = foreach ($release in $releases) {
    Invoke-ComponentBuild -Release $release
    if ($release.testCommand) { & pwsh -NoProfile -NonInteractive -Command $release.testCommand 2>&1 | Out-Host; if ($LASTEXITCODE -ne 0) { throw "Tests failed for $($release.component)." } }
    $package = Invoke-ComponentPackage -Release $release -OutputDirectory $outputRoot
    $containerPackage = if ($config -and $config.components.ContainsKey([string]$release.component)) { Invoke-ComponentContainerPackage -Release $release -Component $config.components[[string]$release.component] -OutputDirectory $outputRoot } else { $null }
    @($package, $containerPackage) | Where-Object { $null -ne $_ }
}
$provenance = [pscustomobject]@{ plan = $plan; artifacts = @($packages); generatedAt = [DateTime]::UtcNow.ToString('o') }
$provenance | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $outputRoot 'provenance.json') -Encoding utf8
$provenance | ConvertTo-Json -Depth 20
