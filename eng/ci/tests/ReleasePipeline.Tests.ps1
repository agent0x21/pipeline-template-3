BeforeAll {
    Import-Module "$PSScriptRoot/../ReleasePipeline/ReleasePipeline.psd1" -Force
    . "$PSScriptRoot/Fixtures.ps1"
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

    It 'propagates affected components through dependencies without changing unrelated components' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{
            common = @{ path = 'src/common'; tagPrefix = 'common' }
            api = @{ path = 'src/api'; tagPrefix = 'api'; dependencies = @('common') }
            web = @{ path = 'src/web'; tagPrefix = 'web' }
        }; branches = @{ develop = @{ channel = 'beta' } } }
        $affected = & (Get-Module ReleasePipeline) { param($cfg) Get-AffectedComponents $cfg @('common') } $config
        @($affected | Sort-Object) | Should -Be @('api','common')
    }

    It 'uses the configured artifact path in a release plan' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'src/app'; tagPrefix = 'app'; package = @{ path = 'out/app' } } }; branches = @{ main = @{ channel = 'stable' } } }
        Mock -ModuleName ReleasePipeline Get-Git { if ($Arguments[0] -eq 'rev-parse') { 'abc123' } else { @() } }
        Mock -ModuleName ReleasePipeline Get-ChangedComponents { @('app') }
        $plan = New-ReleasePlan -Config $config -Branch main -Commit HEAD
        $plan.releases[0].artifactPath | Should -Be 'out/app'
    }
}

Describe 'Release configuration validation' {
    BeforeEach {
        $configPath = Join-Path $TestDrive 'release-config.json'
        New-Item -ItemType Directory -Force -Path (Join-Path $TestDrive 'apps/app') | Out-Null
    }

    It 'rejects a missing dependency' {
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; dependencies = @('missing') } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*missing dependency*'
    }

    It 'rejects dependency cycles, duplicate prefixes, and paths outside the repository' {
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'shared'; dependencies = @('worker') }; worker = @{ path = 'apps/app'; tagPrefix = 'shared'; dependencies = @('app') } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*duplicates tagPrefix*'

        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ app = @{ path = '../outside'; tagPrefix = 'app' } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*within the configuration directory*'

        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; dependencies = @('worker') }; worker = @{ path = 'apps/app'; tagPrefix = 'worker'; dependencies = @('app') } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*contains a cycle*'
    }
}

Describe 'Git release fixtures' {
    It 'calculates stable and prerelease versions from namespaced tags' {
        $stable = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $prerelease = New-ReleaseFixtureRepository -Root $TestDrive -Scenario prerelease
        try {
            Push-Location $stable.Repository
            (New-ReleasePlan -Config $stable.Config -Branch main -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0'
            $exactPlan = New-ReleasePlan -Config $stable.Config -Branch main -BaseRef HEAD~1 -ExactVersions @{ app = '1.4.0' }
            $exactPlan.releases[0].semanticVersion | Should -Be '1.4.0'
            $exactPlan.releases[0].bumpSource | Should -Be 'exact-version'
        } finally { Pop-Location }
        try {
            Push-Location $prerelease.Repository
            (New-ReleasePlan -Config $prerelease.Config -Branch develop -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0-beta.3'
            (New-ReleasePlan -Config $prerelease.Config -Branch qa -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0-rc.2'
        } finally { Pop-Location }
    }

    It 'ignores legacy tags and reuses the existing tag when planning a rerun' {
        $legacy = New-ReleaseFixtureRepository -Root $TestDrive -Scenario legacy
        $rerun = New-ReleaseFixtureRepository -Root $TestDrive -Scenario rerun
        try {
            Push-Location $legacy.Repository
            (New-ReleasePlan -Config $legacy.Config -Branch main -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0'
        } finally { Pop-Location }
        try {
            Push-Location $rerun.Repository
            $plan = New-ReleasePlan -Config $rerun.Config -Branch develop -BaseRef HEAD~1
            $plan.releases[0].semanticVersion | Should -Be '1.3.0-beta.1'
            $plan.releases[0].bumpSource | Should -Be 'rerun'
        } finally { Pop-Location }
    }

    It 'rejects a tag conflict and preserves an idempotent tag' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario conflict
        try {
            Push-Location $fixture.Repository
            $conflict = [pscustomobject]@{ tag = 'app/v1.3.0-beta.1'; component = 'app'; semanticVersion = '1.3.0-beta.1'; commit = $fixture.Head }
            { New-ReleaseTag -Release $conflict } | Should -Throw '*another commit*'

            $idempotent = [pscustomobject]@{ tag = 'app/v1.2.3'; component = 'app'; semanticVersion = '1.2.3'; commit = $fixture.InitialCommit }
            (New-ReleaseTag -Release $idempotent).status | Should -Be 'already-exists'
        } finally { Pop-Location }
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
