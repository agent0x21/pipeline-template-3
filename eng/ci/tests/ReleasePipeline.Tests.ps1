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
