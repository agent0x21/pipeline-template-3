param([Parameter(Mandatory)][string]$PlanPath, [string]$OutputDirectory = 'artifacts')
Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$plan = Get-Content $PlanPath -Raw | ConvertFrom-Json
$repoRoot = (Get-Location).Path
$packages = foreach ($release in $plan.releases) {
    Invoke-ComponentBuild -Release $release
    if ($release.testCommand) { & pwsh -NoProfile -NonInteractive -Command $release.testCommand 2>&1 | Out-Host; if ($LASTEXITCODE -ne 0) { throw "Tests failed for $($release.component)." } }
    Invoke-ComponentPackage -Release $release -OutputDirectory $OutputDirectory
}
$provenance = [pscustomobject]@{ plan = $plan; artifacts = @($packages); generatedAt = [DateTime]::UtcNow.ToString('o') }
$provenance | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutputDirectory 'provenance.json') -Encoding utf8
$provenance | ConvertTo-Json -Depth 20
