BeforeAll {
    Import-Module "$PSScriptRoot/../ReleasePipeline/ReleasePipeline.psd1" -Force
}

Describe 'Release configuration and channels' {
    It 'loads the sample configuration with minor as the default' {
        $config = Import-ReleaseConfig "$PSScriptRoot/../../../.releasepipeline.yml"
        $config.versioning.defaultBump | Should -Be 'minor'
        (Get-ReleaseChannel $config 'develop') | Should -Be 'beta'
        (Get-ReleaseChannel $config 'main') | Should -Be 'stable'
    }
}

Describe 'Release planning' {
    It 'rejects an unsupported branch without creating releases' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps'; tagPrefix = 'app'; initialVersion = '1.0.0' } }; branches = @{} }
        (New-ReleasePlan -Config $config -Branch 'feature/test' -Commit 'HEAD').releases.Count | Should -Be 0
    }

    It 'gives component overrides precedence over workflow overrides' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{}; branches = @{ develop = @{ channel = 'beta' } } }
        $bump = & (Get-Module ReleasePipeline) { param($cfg) Resolve-Bump 'app' $cfg 'patch' @{ app = 'major' } } $config
        $bump.Type | Should -Be 'major'; $bump.Source | Should -Be 'component'
    }

    It 'uses the configured artifact path in a release plan' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'src/app'; tagPrefix = 'app'; package = @{ path = 'out/app' } } }; branches = @{ main = @{ channel = 'stable' } } }
        Mock -ModuleName ReleasePipeline Get-Git { if ($Arguments[0] -eq 'rev-parse') { 'abc123' } else { @() } }
        Mock -ModuleName ReleasePipeline Get-ChangedComponents { @('app') }
        $plan = New-ReleasePlan -Config $config -Branch main -Commit HEAD
        $plan.releases[0].artifactPath | Should -Be 'out/app'
    }
}

Describe 'Release packaging flow' {
    It 'creates a nonexistent output directory and writes empty provenance for an empty plan' {
        $planPath = Join-Path $TestDrive 'empty-plan.json'
        $outputPath = Join-Path $TestDrive 'new-artifacts'
        @{ branch = 'feature/test'; channel = $null; releases = @() } | ConvertTo-Json | Set-Content $planPath

        & "$PSScriptRoot/../Invoke-ReleasePackage.ps1" -PlanPath $planPath -OutputDirectory $outputPath | Out-Null

        Test-Path (Join-Path $outputPath 'provenance.json') | Should -BeTrue
        (Get-Content (Join-Path $outputPath 'provenance.json') -Raw | ConvertFrom-Json).artifacts.Count | Should -Be 0
    }

    It 'packages a release into the requested output directory' {
        $planPath = Join-Path $TestDrive 'release-plan.json'
        $outputPath = Join-Path $TestDrive 'normal-artifacts'
        $release = [pscustomobject]@{
            component = 'web'; path = 'apps/web'; artifactPath = 'apps/web/dist'; semanticVersion = '0.1.0';
            tag = 'web/v0.1.0'; channel = 'stable'; bump = 'minor'; bumpSource = 'configuration';
            commit = 'abc123'; buildCommand = 'Write-Output ready'; testCommand = '';
            componentType = 'node'; buildSolution = ''; buildMsbuildPath = ''; buildConfiguration = 'Release'
        }
        [pscustomobject]@{ branch = 'main'; channel = 'stable'; releases = @($release) } | ConvertTo-Json -Depth 10 | Set-Content $planPath

        $artifactPath = Join-Path $TestDrive 'apps/web/dist'
        try {
            Push-Location $TestDrive
            New-Item -ItemType Directory -Path $artifactPath -Force | Out-Null
            Set-Content (Join-Path $artifactPath 'index.html') 'ready'

            & "$PSScriptRoot/../Invoke-ReleasePackage.ps1" -PlanPath $planPath -OutputDirectory $outputPath | Out-Null
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $artifactPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        $zip = @(Get-ChildItem $outputPath -Filter '*.zip' -Recurse)
        $zip.Count | Should -Be 1
        (Get-Content (Join-Path $outputPath 'provenance.json') -Raw | ConvertFrom-Json).artifacts.Count | Should -Be 1
    }
}
