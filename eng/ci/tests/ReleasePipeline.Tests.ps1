BeforeAll {
    Import-Module "$PSScriptRoot/../ReleasePipeline/ReleasePipeline.psd1" -Force
    . "$PSScriptRoot/Fixtures.ps1"
}
Describe 'Release configuration and channels' {
    It 'loads the sample configuration with minor as the default' {
        $config = Import-ReleaseConfig "$PSScriptRoot/../../../.releasepipeline.yml"
        $config.versioning.defaultBump | Should -Be 'minor'
        (Get-ReleaseChannel $config 'dev') | Should -Be 'beta'
        (Get-ReleaseChannel $config 'main') | Should -Be 'stable'
    }
}

Describe 'Release planning' {
    It 'rejects an unsupported branch without creating releases' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps'; tagPrefix = 'app'; initialVersion = '1.0.0' } }; branches = @{} }
        (New-ReleasePlan -Config $config -Branch 'feature/test' -Commit 'HEAD').releases.Count | Should -Be 0
    }

    It 'gives component overrides precedence over workflow overrides' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{}; branches = @{ dev = @{ channel = 'beta' } } }
        $bump = & (Get-Module ReleasePipeline) { param($cfg) Resolve-Bump 'app' $cfg 'patch' @{ app = 'major' } } $config
        $bump.Type | Should -Be 'major'; $bump.Source | Should -Be 'component'
    }

    It 'propagates affected components through dependencies without changing unrelated components' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{
            common = @{ path = 'src/common'; tagPrefix = 'common' }
            api = @{ path = 'src/api'; tagPrefix = 'api'; dependencies = @('common') }
            web = @{ path = 'src/web'; tagPrefix = 'web' }
        }; branches = @{ dev = @{ channel = 'beta' } } }
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
    It 'creates an initial prerelease for every changed component on a root commit' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario bootstrap
        try {
            Push-Location $fixture.Repository
            $plan = New-ReleasePlan -Config $fixture.Config -Branch dev
            $plan.releases.Count | Should -Be 1
            $plan.releases[0].semanticVersion | Should -Be '0.1.0-beta.1'
            $plan.releases[0].tag | Should -Be 'app/v0.1.0-beta.1'
        } finally { Pop-Location }
    }

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
            (New-ReleasePlan -Config $prerelease.Config -Branch dev -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.4.0-beta.1'
            (New-ReleasePlan -Config $prerelease.Config -Branch qa -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0-rc.2'
            { New-ReleasePlan -Config $prerelease.Config -Branch dev -BaseRef HEAD~1 -ExactVersions @{ app = '1.3.0' } } | Should -Throw '*channel version floor*'
            { New-ReleasePlan -Config $prerelease.Config -Branch qa -BaseRef HEAD~1 -ExactVersions @{ app = '1.2.0' } } | Should -Throw '*channel version floor*'
        } finally { Pop-Location }
    }

    It 'detects component changes across the complete promoted branch range' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        try {
            # The component change is in the first commit of the promoted range;
            # the tip commit is deliberately outside every component path.
            Set-Content -LiteralPath (Join-Path $fixture.Repository 'release-notes.md') -Value 'second promoted change'
            Invoke-FixtureGit $fixture.Repository @('add','release-notes.md') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Second promoted change') | Out-Null

            Push-Location $fixture.Repository
            $plan = New-ReleasePlan -Config $fixture.Config -Branch qa -BaseRef $fixture.InitialCommit

            $plan.releases.Count | Should -Be 1
            $plan.releases[0].component | Should -Be 'app'
        } finally { Pop-Location }
    }

    It 'finds the immutable beta source for an unambiguous branch promotion' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $configPath = Join-Path $fixture.Repository 'release-config.json'
        $outputPath = Join-Path $fixture.Repository 'promotion-sources.json'
        $fixture.Config | ConvertTo-Json -Depth 12 | Set-Content $configPath
        try {
            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.3.0-beta.1',$fixture.Head) | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.Repository 'release-notes.md') -Value 'promote the beta release'
            Invoke-FixtureGit $fixture.Repository @('add','release-notes.md') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Promote candidate') | Out-Null

            Push-Location $fixture.Repository
            & "$PSScriptRoot/../Find-BranchPromotionSources.ps1" -ConfigPath $configPath -TargetChannel rc -BaseRef $fixture.InitialCommit -OutputPath $outputPath | Out-Null
            $sources = Get-Content $outputPath -Raw | ConvertFrom-Json

            $sources.sourceChannel | Should -Be 'beta'
            $sources.sources.Count | Should -Be 1
            $sources.sources[0].tag | Should -Be 'app/v1.3.0-beta.1'
        } finally { Pop-Location }
    }

    It 'promotes the newest sequential beta tag instead of failing on a superseded predecessor' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $configPath = Join-Path $fixture.Repository 'release-config.json'
        $outputPath = Join-Path $fixture.Repository 'promotion-sources.json'
        $fixture.Config | ConvertTo-Json -Depth 12 | Set-Content $configPath
        try {
            # Two beta iterations of the same base version both land inside the
            # pushed range, as happens when dev accumulates beta.1 then beta.2
            # before a single multi-commit push promotes the branch.
            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.3.0-beta.1',$fixture.Head) | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.Repository 'release-notes.md') -Value 'fix before second beta'
            Invoke-FixtureGit $fixture.Repository @('add','release-notes.md') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Fix before second beta') | Out-Null
            $secondBetaCommit = Invoke-FixtureGit $fixture.Repository @('rev-parse','HEAD') | Select-Object -First 1
            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.3.0-beta.2',$secondBetaCommit) | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.Repository 'release-notes.md') -Value 'promote the beta release'
            Invoke-FixtureGit $fixture.Repository @('add','release-notes.md') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Promote candidate') | Out-Null

            Push-Location $fixture.Repository
            & "$PSScriptRoot/../Find-BranchPromotionSources.ps1" -ConfigPath $configPath -TargetChannel rc -BaseRef $fixture.InitialCommit -OutputPath $outputPath | Out-Null
            $sources = Get-Content $outputPath -Raw | ConvertFrom-Json

            $sources.sources.Count | Should -Be 1
            $sources.sources[0].tag | Should -Be 'app/v1.3.0-beta.2'
        } finally { Pop-Location }
    }

    It 'rejects genuinely conflicting base versions introduced by the same branch promotion' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $configPath = Join-Path $fixture.Repository 'release-config.json'
        $outputPath = Join-Path $fixture.Repository 'promotion-sources.json'
        $fixture.Config | ConvertTo-Json -Depth 12 | Set-Content $configPath
        try {
            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.3.0-beta.1',$fixture.Head) | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.Repository 'apps/app/source.txt') -Value 'changed again for next base version'
            Invoke-FixtureGit $fixture.Repository @('add','apps/app/source.txt') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Bump app for next base version') | Out-Null
            $nextBaseCommit = Invoke-FixtureGit $fixture.Repository @('rev-parse','HEAD') | Select-Object -First 1
            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.4.0-beta.1',$nextBaseCommit) | Out-Null

            Push-Location $fixture.Repository
            { & "$PSScriptRoot/../Find-BranchPromotionSources.ps1" -ConfigPath $configPath -TargetChannel rc -BaseRef $fixture.InitialCommit -OutputPath $outputPath } | Should -Throw '*conflicting*'
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
            $plan = New-ReleasePlan -Config $rerun.Config -Branch dev -BaseRef HEAD~1
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

    It 'releases all configured components only when explicitly requested' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        try {
            Push-Location $fixture.Repository
            $plan = New-ReleasePlan -Config $fixture.Config -Branch dev -BaseRef HEAD -ReleaseAll
            $plan.releases.Count | Should -Be 1
            $plan.releases[0].semanticVersion | Should -Be '1.3.0-beta.1'
        } finally { Pop-Location }
    }

    It 'reuses a remotely claimed matching tag after an atomic push race' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $remote = Join-Path $TestDrive 'remote.git'
        $publisher = Join-Path $TestDrive 'publisher'
        & git init --bare $remote | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the fixture remote.' }
        try {
            Invoke-FixtureGit $fixture.Repository @('remote','add','origin',$remote) | Out-Null
            Invoke-FixtureGit $fixture.Repository @('push','origin','HEAD:refs/heads/main') | Out-Null
            & git clone $remote $publisher | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not clone the fixture remote.' }
            Invoke-FixtureGit $publisher @('config','user.email','release-fixture@example.invalid') | Out-Null
            Invoke-FixtureGit $publisher @('config','user.name','Release Fixture') | Out-Null
            Invoke-FixtureGit $publisher @('tag','-a','app/v1.3.0-beta.1',$fixture.Head,'-m','Concurrent release') | Out-Null
            Invoke-FixtureGit $publisher @('push','origin','app/v1.3.0-beta.1') | Out-Null

            Push-Location $fixture.Repository
            $release = [pscustomobject]@{ tag = 'app/v1.3.0-beta.1'; component = 'app'; semanticVersion = '1.3.0-beta.1'; commit = $fixture.Head }
            (New-ReleaseTag -Release $release -Push -PushAttempts 2).status | Should -Be 'already-exists'
            @(Invoke-FixtureGit $fixture.Repository @('tag','--list','app/v1.3.0-beta.1')).Count | Should -Be 0
        } finally { Pop-Location }
    }
}

Describe 'Artifact promotion planning' {
    It 'promotes a beta artifact to the next RC without rebuilding it' {
        $provenancePath = Join-Path $TestDrive 'provenance.json'
        [pscustomobject]@{
            plan = [pscustomobject]@{ releases = @([pscustomobject]@{ component = 'app'; semanticVersion = '2.1.0-beta.4'; channel = 'beta'; tag = 'app/v2.1.0-beta.4'; commit = 'abc123' }) }
            artifacts = @([pscustomobject]@{ component = 'app'; semanticVersion = '2.1.0-beta.4'; path = 'artifacts/app.zip'; sha256 = ('a' * 64) })
        } | ConvertTo-Json -Depth 8 | Set-Content $provenancePath
        $config = @{ components = @{ app = @{ tagPrefix = 'app'; path = 'apps/app' } } }
        Mock -ModuleName ReleasePipeline Get-Git { @('app/v2.1.0-rc.2') }

        $plan = New-ArtifactPromotionPlan -Config $config -ProvenancePath $provenancePath -TargetChannel rc

        $plan.promotions.Count | Should -Be 1
        $plan.promotions[0].semanticVersion | Should -Be '2.1.0-rc.3'
        $plan.promotions[0].tag | Should -Be 'app/v2.1.0-rc.3'
        $plan.promotions[0].sourceSha256 | Should -Be ('a' * 64)
    }

    It 'rejects promotion paths that skip the RC channel' {
        $provenancePath = Join-Path $TestDrive 'beta-provenance.json'
        [pscustomobject]@{
            plan = [pscustomobject]@{ releases = @([pscustomobject]@{ component = 'app'; semanticVersion = '2.1.0-beta.1'; channel = 'beta'; tag = 'app/v2.1.0-beta.1'; commit = 'abc123' }) }
            artifacts = @([pscustomobject]@{ component = 'app'; semanticVersion = '2.1.0-beta.1'; path = 'artifacts/app.zip'; sha256 = ('b' * 64) })
        } | ConvertTo-Json -Depth 8 | Set-Content $provenancePath
        $config = @{ components = @{ app = @{ tagPrefix = 'app'; path = 'apps/app' } } }

        { New-ArtifactPromotionPlan -Config $config -ProvenancePath $provenancePath -TargetChannel stable } | Should -Throw '*beta -> rc -> stable*'
    }
}

Describe 'GitHub release asset publication' {
    It 'resolves every component artifact from a downloaded release bundle' {
        $bundlePath = Join-Path $TestDrive 'downloaded-release'
        $artifactPath = Join-Path $bundlePath 'artifacts'
        $webPath = Join-Path $artifactPath 'web/web-v1.0.0-beta.1.zip'
        $desktopPath = Join-Path $artifactPath 'desktop/desktop-v1.0.0-beta.1.zip'
        New-Item -ItemType Directory -Force -Path (Split-Path $webPath), (Split-Path $desktopPath) | Out-Null
        Set-Content -LiteralPath $webPath -Value 'web artifact'
        Set-Content -LiteralPath $desktopPath -Value 'desktop artifact'
        $provenancePath = Join-Path $artifactPath 'provenance.json'
        $planPath = Join-Path $bundlePath 'release-plan.json'
        $webHash = (Get-FileHash $webPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $desktopHash = (Get-FileHash $desktopPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $releasePlan = [pscustomobject]@{ releases = @(
            [pscustomobject]@{ component = 'web'; semanticVersion = '1.0.0-beta.1'; channel = 'beta'; tag = 'web/v1.0.0-beta.1'; commit = 'abc123' },
            [pscustomobject]@{ component = 'desktop'; semanticVersion = '1.0.0-beta.1'; channel = 'beta'; tag = 'desktop/v1.0.0-beta.1'; commit = 'abc123' }
        ) }
        [pscustomobject]@{
            plan = $releasePlan
            artifacts = @(
                [pscustomobject]@{ component = 'web'; semanticVersion = '1.0.0-beta.1'; path = 'D:\original\artifacts\web\web-v1.0.0-beta.1.zip'; sha256 = $webHash; artifactType = 'zip' },
                [pscustomobject]@{ component = 'desktop'; semanticVersion = '1.0.0-beta.1'; path = 'D:\original\artifacts\desktop\desktop-v1.0.0-beta.1.zip'; sha256 = $desktopHash; artifactType = 'zip' }
            )
        } | ConvertTo-Json -Depth 12 | Set-Content $provenancePath
        $releasePlan | ConvertTo-Json -Depth 12 | Set-Content $planPath

        Mock Invoke-RestMethod { [pscustomobject]@{ id = 1; tag_name = 'test'; assets = @() } }
        $oldRepository = $env:GITHUB_REPOSITORY; $oldToken = $env:GITHUB_TOKEN
        try {
            $env:GITHUB_REPOSITORY = 'example/repository'; $env:GITHUB_TOKEN = 'test-token'
            & "$PSScriptRoot/../providers/github/Publish-GitHubReleaseAssets.ps1" -PlanPath $planPath -ProvenancePath $provenancePath
        } finally {
            $env:GITHUB_REPOSITORY = $oldRepository; $env:GITHUB_TOKEN = $oldToken
        }

        Should -Invoke Invoke-RestMethod -Times 6 -Exactly
    }

    It 'resolves artifacts from a promotion plan that uses the promotions schema' {
        $bundlePath = Join-Path $TestDrive 'promoted-release'
        $artifactPath = Join-Path $bundlePath 'artifacts'
        $appPath = Join-Path $artifactPath 'app/app-v2.1.0-beta.4.zip'
        New-Item -ItemType Directory -Force -Path (Split-Path $appPath) | Out-Null
        Set-Content -LiteralPath $appPath -Value 'app artifact'
        $provenancePath = Join-Path $artifactPath 'provenance.json'
        $planPath = Join-Path $bundlePath 'promotion-plan.json'
        $appHash = (Get-FileHash $appPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [pscustomobject]@{
            plan = [pscustomobject]@{ releases = @([pscustomobject]@{ component = 'app'; semanticVersion = '2.1.0-beta.4'; channel = 'beta'; tag = 'app/v2.1.0-beta.4'; commit = 'abc123' }) }
            artifacts = @([pscustomobject]@{ component = 'app'; semanticVersion = '2.1.0-beta.4'; path = 'D:\original\artifacts\app\app-v2.1.0-beta.4.zip'; sha256 = $appHash; artifactType = 'zip' })
        } | ConvertTo-Json -Depth 12 | Set-Content $provenancePath
        # Promotion plans (New-ArtifactPromotionPlan.ps1) expose 'promotions', not
        # 'releases'. This is the schema that Publish-GitHubReleaseAssets.ps1 and
        # Publish-GitHubReleaseMetadata.ps1 must also handle for a promotion run.
        [pscustomobject]@{ targetChannel = 'rc'; promotions = @(
            [pscustomobject]@{ component = 'app'; semanticVersion = '2.1.0-rc.1'; channel = 'rc'; tag = 'app/v2.1.0-rc.1'; commit = 'abc123'; sourceSemanticVersion = '2.1.0-beta.4' }
        ) } | ConvertTo-Json -Depth 12 | Set-Content $planPath

        Mock Invoke-RestMethod { [pscustomobject]@{ id = 1; tag_name = 'test'; assets = @() } }
        $oldRepository = $env:GITHUB_REPOSITORY; $oldToken = $env:GITHUB_TOKEN
        try {
            $env:GITHUB_REPOSITORY = 'example/repository'; $env:GITHUB_TOKEN = 'test-token'
            & "$PSScriptRoot/../providers/github/Publish-GitHubReleaseAssets.ps1" -PlanPath $planPath -ProvenancePath $provenancePath
            & "$PSScriptRoot/../providers/github/Publish-GitHubReleaseMetadata.ps1" -PlanPath $planPath
        } finally {
            $env:GITHUB_REPOSITORY = $oldRepository; $env:GITHUB_TOKEN = $oldToken
        }

        Should -Invoke Invoke-RestMethod -Times 4 -Exactly
    }

    It 'rejects a plan file with neither a releases nor a promotions property' {
        $planPath = Join-Path $TestDrive 'malformed-plan.json'
        [pscustomobject]@{ targetChannel = 'rc' } | ConvertTo-Json -Depth 4 | Set-Content $planPath
        $oldRepository = $env:GITHUB_REPOSITORY; $oldToken = $env:GITHUB_TOKEN
        try {
            $env:GITHUB_REPOSITORY = 'example/repository'; $env:GITHUB_TOKEN = 'test-token'
            { & "$PSScriptRoot/../providers/github/Publish-GitHubReleaseMetadata.ps1" -PlanPath $planPath } | Should -Throw '*Unrecognized plan schema*'
        } finally {
            $env:GITHUB_REPOSITORY = $oldRepository; $env:GITHUB_TOKEN = $oldToken
        }
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

    It 'executes container packaging through the manifest-imported packaging script' {
        $root = Join-Path $TestDrive 'container-package'
        $componentPath = Join-Path $root 'apps/api'
        $shimPath = Join-Path $root 'bin'
        $configPath = Join-Path $root 'release-config.json'
        $planPath = Join-Path $root 'release-plan.json'
        $outputPath = Join-Path $root 'artifacts'
        New-Item -ItemType Directory -Force -Path $componentPath, $shimPath | Out-Null
        Set-Content (Join-Path $componentPath 'Dockerfile') 'FROM scratch'
        Set-Content (Join-Path $shimPath 'docker.ps1') @'
param([string]$Operation, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
if ($Operation -eq 'save') {
    $outputIndex = [Array]::IndexOf($Arguments, '--output')
    if ($outputIndex -lt 0) { exit 1 }
    Set-Content -LiteralPath $Arguments[$outputIndex + 1] -Value 'container image'
}
if ($Operation -eq 'build') {
    Set-Content -LiteralPath (Join-Path (Split-Path $MyInvocation.MyCommand.Path) 'build-args.txt') -Value ($Arguments -join "`n")
}
exit 0
'@
        @{
            versioning = @{ defaultBump = 'minor' }
            branches = @{ main = @{ channel = 'stable' } }
            components = @{ api = @{
                path = 'apps/api'; tagPrefix = 'api'
                build = @{ command = 'Write-Output ready' }
                package = @{ path = 'apps/api' }
                publishing = @{ adapter = 'container'; image = 'example.invalid/api'; dockerfile = 'apps/api/Dockerfile'; context = 'apps/api' }
            } }
        } | ConvertTo-Json -Depth 12 | Set-Content $configPath
        [pscustomobject]@{
            branch = 'main'; channel = 'stable'; releases = @([pscustomobject]@{
                component = 'api'; path = 'apps/api'; artifactPath = 'apps/api'; semanticVersion = '0.1.0-beta.2'
                tag = 'api/v0.1.0-beta.2'; channel = 'beta'; bump = 'minor'; bumpSource = 'configuration'
                commit = 'abc123'; buildCommand = 'Write-Output ready'; testCommand = ''
                componentType = 'modern-dotnet'; buildSolution = ''; buildMsbuildPath = ''; buildConfiguration = 'Release'
            })
        } | ConvertTo-Json -Depth 10 | Set-Content $planPath

        $oldPath = $env:PATH
        try {
            $env:PATH = "$shimPath$([IO.Path]::PathSeparator)$oldPath"
            Push-Location $root
            & "$PSScriptRoot/../Invoke-ReleasePackage.ps1" -PlanPath $planPath -ConfigPath $configPath -OutputDirectory $outputPath | Out-Null
        } finally {
            Pop-Location
            $env:PATH = $oldPath
        }

        @(Get-ChildItem $outputPath -Filter '*.zip' -Recurse).Count | Should -Be 1
        @(Get-ChildItem $outputPath -Filter '*.container.tar' -Recurse).Count | Should -Be 1
        (Get-Content (Join-Path $outputPath 'provenance.json') -Raw | ConvertFrom-Json).artifacts.Count | Should -Be 2
        $buildArgs = Get-Content (Join-Path $shimPath 'build-args.txt')
        $buildArgs | Should -Contain 'DOTNET_Version=0.1.0-beta.2'
        $buildArgs | Should -Contain 'DOTNET_VersionPrefix=0.1.0'
        $buildArgs | Should -Contain 'DOTNET_VersionSuffix=beta.2'
        $buildArgs | Should -Contain 'DOTNET_AssemblyVersion=0.1.0.0'
        $buildArgs | Should -Contain 'DOTNET_FileVersion=0.1.0.0'
        $buildArgs | Should -Contain 'DOTNET_InformationalVersion=0.1.0-beta.2'
    }
}

Describe 'Registry publication planning' {
    It 'keeps the source digest while assigning the promoted target version' {
        $componentPath = Join-Path $TestDrive 'apps/app'
        New-Item -ItemType Directory -Force -Path $componentPath | Out-Null
        $configPath = Join-Path $TestDrive 'release-config.json'
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; publishing = @{ adapter = 'npm'; endpoint = 'https://registry.example.invalid'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
        $provenancePath = Join-Path $TestDrive 'provenance.json'
        @{ plan = @{ releases = @(@{ component = 'app'; semanticVersion = '2.1.0-beta.1'; channel = 'beta'; commit = 'abc123' }) }; artifacts = @(@{ component = 'app'; semanticVersion = '2.1.0-beta.1'; path = 'app.tgz'; sha256 = ('c' * 64) }) } | ConvertTo-Json -Depth 12 | Set-Content $provenancePath
        $promotionPath = Join-Path $TestDrive 'promotion-plan.json'
        @{ promotions = @(@{ component = 'app'; semanticVersion = '2.1.0-rc.1'; sourceSemanticVersion = '2.1.0-beta.1'; channel = 'rc'; commit = 'abc123' }) } | ConvertTo-Json -Depth 12 | Set-Content $promotionPath

        $planPath = Join-Path $TestDrive 'registry-plan.json'
        & "$PSScriptRoot/../New-RegistryPublicationPlan.ps1" -ProvenancePath $provenancePath -PromotionPlanPath $promotionPath -ConfigPath $configPath -OutputPath $planPath | Out-Null
        $plan = Get-Content $planPath -Raw | ConvertFrom-Json
        $plan.publications[0].semanticVersion | Should -Be '2.1.0-rc.1'
        $plan.publications[0].sha256 | Should -Be ('c' * 64)
    }

    It 'selects the immutable container image artifact for a container publication' {
        $componentPath = Join-Path $TestDrive 'apps/api'
        New-Item -ItemType Directory -Force -Path $componentPath | Out-Null
        $configPath = Join-Path $TestDrive 'container-release-config.json'
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ api = @{ path = 'apps/api'; tagPrefix = 'api'; publishing = @{ adapter = 'container'; image = 'example.invalid/api'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
        $provenancePath = Join-Path $TestDrive 'container-provenance.json'
        @{ plan = @{ releases = @(@{ component = 'api'; semanticVersion = '1.2.0'; channel = 'stable'; commit = 'abc123' }) }; artifacts = @(
            @{ component = 'api'; semanticVersion = '1.2.0'; path = 'api.zip'; sha256 = ('a' * 64); artifactType = 'zip' },
            @{ component = 'api'; semanticVersion = '1.2.0'; path = 'api.container.tar'; sha256 = ('b' * 64); artifactType = 'container-image' }
        ) } | ConvertTo-Json -Depth 12 | Set-Content $provenancePath

        $planPath = Join-Path $TestDrive 'container-registry-plan.json'
        & "$PSScriptRoot/../New-RegistryPublicationPlan.ps1" -ProvenancePath $provenancePath -ConfigPath $configPath -OutputPath $planPath | Out-Null
        $plan = Get-Content $planPath -Raw | ConvertFrom-Json
        $plan.publications[0].artifactPath | Should -Be 'api.container.tar'
        $plan.publications[0].sha256 | Should -Be ('b' * 64)
    }
}

Describe 'Registry publication recovery' {
    It 'retries only the requested component without publishing it in WhatIf mode' {
        $artifactPath = Join-Path $TestDrive 'api.tgz'
        New-Item -ItemType File -Path $artifactPath -Force | Out-Null
        $planPath = Join-Path $TestDrive 'registry-publication-plan.json'
        $resultPath = Join-Path $TestDrive 'registry-publication-retry.json'
        @{ publications = @(
            @{ component = 'api'; adapter = 'npm'; semanticVersion = '1.2.0'; artifactPath = $artifactPath; endpoint = 'https://registry.example.invalid'; oidc = $true; sha256 = ('d' * 64) },
            @{ component = 'web'; adapter = 'npm'; semanticVersion = '1.2.0'; artifactPath = $artifactPath; endpoint = 'https://registry.example.invalid'; oidc = $true; sha256 = ('e' * 64) }
        ) } | ConvertTo-Json -Depth 8 | Set-Content $planPath

        $resultJson = & "$PSScriptRoot/../Publish-RegistryArtifacts.ps1" -PlanPath $planPath -Component api -WhatIf -OutputPath $resultPath

        Test-Path $resultPath | Should -BeFalse
        $result = ($resultJson -join [Environment]::NewLine) | ConvertFrom-Json
        $result.publications.Count | Should -Be 1
        $result.publications[0].component | Should -Be 'api'
        $result.publications[0].status | Should -Be 'planned'
    }
}

Describe 'Registry publication planning' {
    It 'keeps the source digest while assigning the promoted target version' {
        $componentPath = Join-Path $TestDrive 'apps/app'
        New-Item -ItemType Directory -Force -Path $componentPath | Out-Null
        $configPath = Join-Path $TestDrive 'release-config.json'
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; publishing = @{ adapter = 'npm'; endpoint = 'https://registry.example.invalid'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
        $provenancePath = Join-Path $TestDrive 'provenance.json'
        @{ plan = @{ releases = @(@{ component = 'app'; semanticVersion = '2.1.0-beta.1'; channel = 'beta'; commit = 'abc123' }) }; artifacts = @(@{ component = 'app'; semanticVersion = '2.1.0-beta.1'; path = 'app.tgz'; sha256 = ('c' * 64) }) } | ConvertTo-Json -Depth 12 | Set-Content $provenancePath
        $promotionPath = Join-Path $TestDrive 'promotion-plan.json'
        @{ promotions = @(@{ component = 'app'; semanticVersion = '2.1.0-rc.1'; sourceSemanticVersion = '2.1.0-beta.1'; channel = 'rc'; commit = 'abc123' }) } | ConvertTo-Json -Depth 12 | Set-Content $promotionPath

        $planPath = Join-Path $TestDrive 'registry-plan.json'
        & "$PSScriptRoot/../New-RegistryPublicationPlan.ps1" -ProvenancePath $provenancePath -PromotionPlanPath $promotionPath -ConfigPath $configPath -OutputPath $planPath | Out-Null
        $plan = Get-Content $planPath -Raw | ConvertFrom-Json
        $plan.publications[0].semanticVersion | Should -Be '2.1.0-rc.1'
        $plan.publications[0].sha256 | Should -Be ('c' * 64)
    }

    It 'selects the immutable container image artifact for a container publication' {
        $componentPath = Join-Path $TestDrive 'apps/api'
        New-Item -ItemType Directory -Force -Path $componentPath | Out-Null
        $configPath = Join-Path $TestDrive 'container-release-config.json'
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ api = @{ path = 'apps/api'; tagPrefix = 'api'; publishing = @{ adapter = 'container'; image = 'example.invalid/api'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
        $provenancePath = Join-Path $TestDrive 'container-provenance.json'
        @{ plan = @{ releases = @(@{ component = 'api'; semanticVersion = '1.2.0'; channel = 'stable'; commit = 'abc123' }) }; artifacts = @(
            @{ component = 'api'; semanticVersion = '1.2.0'; path = 'api.zip'; sha256 = ('a' * 64); artifactType = 'zip' },
            @{ component = 'api'; semanticVersion = '1.2.0'; path = 'api.container.tar'; sha256 = ('b' * 64); artifactType = 'container-image' }
        ) } | ConvertTo-Json -Depth 12 | Set-Content $provenancePath

        $planPath = Join-Path $TestDrive 'container-registry-plan.json'
        & "$PSScriptRoot/../New-RegistryPublicationPlan.ps1" -ProvenancePath $provenancePath -ConfigPath $configPath -OutputPath $planPath | Out-Null
        $plan = Get-Content $planPath -Raw | ConvertFrom-Json
        $plan.publications[0].artifactPath | Should -Be 'api.container.tar'
        $plan.publications[0].sha256 | Should -Be ('b' * 64)
    }
}
