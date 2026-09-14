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

Describe 'Candidate commit capture' {
    It 'accepts a checked-out HEAD that equals the captured candidate SHA' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        try {
            Push-Location $fixture.Repository
            Assert-CandidateCommit -ExpectedSha $fixture.Head | Should -Be $fixture.Head.ToLowerInvariant()
        } finally { Pop-Location }
    }

    It 'fails when HEAD differs from the captured candidate SHA' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        try {
            Push-Location $fixture.Repository
            { Assert-CandidateCommit -ExpectedSha $fixture.InitialCommit } | Should -Throw '*does not equal the captured candidate SHA*'
        } finally { Pop-Location }
    }

    It 'refuses an ambiguous candidate SHA' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        try {
            Push-Location $fixture.Repository
            { Assert-CandidateCommit -ExpectedSha $fixture.Head.Substring(0, 7) } | Should -Throw '*could not be determined unambiguously*'
        } finally { Pop-Location }
    }
}

Describe 'Release identity' {
    BeforeAll {
        $script:candidate = 'a' * 40
        $script:digest = 'sha256:' + ('c' * 64)
        $script:plan = @{ branch = 'dev'; channel = 'beta'; commit = $script:candidate; releases = @(
            @{ component = 'api'; semanticVersion = '1.18.0-beta.1'; channel = 'beta'; tag = 'api/v1.18.0-beta.1'; commit = $script:candidate }
        ) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $script:provenance = @{ artifacts = @(
            @{ component = 'api'; semanticVersion = '1.18.0-beta.1'; artifactType = 'zip'; sha256 = ('d' * 64); path = 'api.zip' }
            @{ component = 'api'; semanticVersion = '1.18.0-beta.1'; artifactType = 'container-image'; sha256 = ('e' * 64); path = 'api.tar'; image = 'ghcr.io/acme/orders' }
        ) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $script:publication = @{ publications = @(
            @{ component = 'api'; adapter = 'container'; semanticVersion = '1.18.0-beta.1'; image = 'ghcr.io/acme/orders'; imageDigest = $script:digest }
        ) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }

    It 'binds the release version, candidate SHA, and immutable artifact digest together' {
        $manifest = New-ReleaseManifest -Plan $script:plan -Provenance $script:provenance -RegistryPublication $script:publication -CandidateSha $script:candidate
        $manifest.candidateSha | Should -Be $script:candidate
        $manifest.releaseId | Should -Be "beta-$($script:candidate.Substring(0,12))"
        $manifest.components[0].imageDigest | Should -Be $script:digest
        $manifest.components[0].archiveSha256 | Should -Be ('d' * 64)
    }

    It 'refuses a manifest whose artifact was built from another commit' {
        { New-ReleaseManifest -Plan $script:plan -Provenance $script:provenance -RegistryPublication $script:publication -CandidateSha ('b' * 40) } |
            Should -Throw '*does not equal the candidate SHA*'
    }

    It 'refuses a container release that has no published registry digest' {
        { New-ReleaseManifest -Plan $script:plan -Provenance $script:provenance -RegistryPublication $null -CandidateSha $script:candidate } |
            Should -Throw '*container publication record*'
    }

    It 'accepts a deployment whose digest equals the approved digest' {
        $manifest = New-ReleaseManifest -Plan $script:plan -Provenance $script:provenance -RegistryPublication $script:publication -CandidateSha $script:candidate
        Assert-ReleaseIdentity -Manifest $manifest -ApprovedManifest $manifest | Should -BeTrue
    }

    It 'fails a production deployment whose digest differs from the approved digest' {
        $approved = New-ReleaseManifest -Plan $script:plan -Provenance $script:provenance -RegistryPublication $script:publication -CandidateSha $script:candidate
        $tampered = $approved | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $tampered.components[0].imageDigest = 'sha256:' + ('f' * 64)
        { Assert-ReleaseIdentity -Manifest $tampered -ApprovedManifest $approved } | Should -Throw '*does not equal the QA-approved digest*'
    }

    It 'fails when an approved component is missing from the deployment' {
        $approved = New-ReleaseManifest -Plan $script:plan -Provenance $script:provenance -RegistryPublication $script:publication -CandidateSha $script:candidate
        $partial = $approved | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $partial.components = @()
        { Assert-ReleaseIdentity -Manifest $partial -ApprovedManifest $approved } | Should -Throw '*is missing from the deployment manifest*'
    }
}

Describe 'Protected branch advancement' {
    It 'prefers a fast-forward and never rewrites the candidate commit' {
        Get-BranchAdvanceStrategy -CurrentSha ('a' * 40) -CandidateSha ('b' * 40) -CurrentIsAncestorOfCandidate $true | Should -Be 'fast-forward'
    }

    It 'treats an identical or already-containing branch as needing no update' {
        Get-BranchAdvanceStrategy -CurrentSha ('a' * 40) -CandidateSha ('a' * 40) | Should -Be 'up-to-date'
        Get-BranchAdvanceStrategy -CurrentSha ('a' * 40) -CandidateSha ('b' * 40) -CandidateIsAncestorOfCurrent $true | Should -Be 'already-contains'
    }

    It 'requires a merge when the branch advanced independently' {
        Get-BranchAdvanceStrategy -CurrentSha ('a' * 40) -CandidateSha ('b' * 40) | Should -Be 'merge'
        Get-BranchAdvanceStrategy -CurrentSha '' -CandidateSha ('b' * 40) | Should -Be 'create'
    }

    It 'fast-forwards qa onto the candidate commit without changing its SHA' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $remote = Join-Path $TestDrive "remote-$([guid]::NewGuid().ToString('N')).git"
        & git init --bare $remote | Out-Null
        Invoke-FixtureGit $fixture.Repository @('remote','add','origin',$remote) | Out-Null
        Invoke-FixtureGit $fixture.Repository @('push','origin',"$($fixture.InitialCommit):refs/heads/qa") | Out-Null
        try {
            Push-Location $fixture.Repository
            & "$PSScriptRoot/../Update-PromotionBranch.ps1" -Branch qa -CandidateSha $fixture.Head -Push -OutputPath (Join-Path $fixture.Repository 'promotion-qa.json') | Out-Null
            $record = Get-Content (Join-Path $fixture.Repository 'promotion-qa.json') -Raw | ConvertFrom-Json
            $record.strategy | Should -Be 'fast-forward'
            $record.resultSha | Should -Be $fixture.Head.ToLowerInvariant()
            $record.mergeCommit | Should -BeNullOrEmpty
            (@(Invoke-FixtureGit $fixture.Repository @('ls-remote','origin','refs/heads/qa')) -join "`n") | Should -BeLike "$($fixture.Head)*"
        } finally { Pop-Location }
    }

    It 'preserves the approved commit in ancestry when main has advanced' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $remote = Join-Path $TestDrive "remote-$([guid]::NewGuid().ToString('N')).git"
        & git init --bare $remote | Out-Null
        Invoke-FixtureGit $fixture.Repository @('remote','add','origin',$remote) | Out-Null
        # main moves on independently with an unrelated change.
        Invoke-FixtureGit $fixture.Repository @('checkout','-b','main-work',$fixture.InitialCommit) | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Repository 'hotfix.txt') -Value 'independent hotfix'
        Invoke-FixtureGit $fixture.Repository @('add','hotfix.txt') | Out-Null
        Invoke-FixtureGit $fixture.Repository @('commit','-m','Independent hotfix on main') | Out-Null
        $mainHead = Invoke-FixtureGit $fixture.Repository @('rev-parse','HEAD') | Select-Object -First 1
        Invoke-FixtureGit $fixture.Repository @('push','origin',"$($mainHead):refs/heads/main") | Out-Null
        try {
            Push-Location $fixture.Repository
            { & "$PSScriptRoot/../Update-PromotionBranch.ps1" -Branch main -CandidateSha $fixture.Head -Push -OutputPath (Join-Path $fixture.Repository 'p.json') } |
                Should -Throw '*cannot fast-forward*'

            & "$PSScriptRoot/../Update-PromotionBranch.ps1" -Branch main -CandidateSha $fixture.Head -AllowMerge -Push -OutputPath (Join-Path $fixture.Repository 'promotion-main.json') | Out-Null
            $record = Get-Content (Join-Path $fixture.Repository 'promotion-main.json') -Raw | ConvertFrom-Json
            $record.strategy | Should -Be 'merge'
            $record.approvedSha | Should -Be $fixture.Head.ToLowerInvariant()
            $record.mergeCommit | Should -Not -BeNullOrEmpty
            # The QA-approved commit is unchanged and contained by the promotion commit.
            Invoke-FixtureGit $fixture.Repository @('merge-base','--is-ancestor',$fixture.Head,$record.mergeCommit) | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally { Pop-Location }
    }

    It 'fails when the promotion branch moved unexpectedly' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $remote = Join-Path $TestDrive "remote-$([guid]::NewGuid().ToString('N')).git"
        & git init --bare $remote | Out-Null
        Invoke-FixtureGit $fixture.Repository @('remote','add','origin',$remote) | Out-Null
        Invoke-FixtureGit $fixture.Repository @('push','origin',"$($fixture.InitialCommit):refs/heads/qa") | Out-Null
        try {
            Push-Location $fixture.Repository
            { & "$PSScriptRoot/../Update-PromotionBranch.ps1" -Branch qa -CandidateSha $fixture.Head -ExpectedSha ('9' * 40) -Push } |
                Should -Throw '*changed during promotion*'
        } finally { Pop-Location }
    }
}

Describe 'Manifest-driven promotion' {
    It 'creates the next RC for the candidate commit and requires an RC before stable' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $manifest = [pscustomobject]@{
            schema = 'release-manifest/v1'
            releaseId = 'beta-test'
            candidateSha = $fixture.Head.ToLowerInvariant()
            components = @([pscustomobject]@{ component = 'app'; semanticVersion = '1.3.0-beta.1'; tag = 'app/v1.3.0-beta.1'; imageDigest = $null; archiveSha256 = ('d' * 64) })
        }
        try {
            Push-Location $fixture.Repository
            { New-ManifestPromotionPlan -Config $fixture.Config -Manifest $manifest -TargetChannel stable } |
                Should -Throw '*beta -> rc -> stable*'

            $rc = New-ManifestPromotionPlan -Config $fixture.Config -Manifest $manifest -TargetChannel rc
            $rc.promotions[0].semanticVersion | Should -Be '1.3.0-rc.1'
            $rc.promotions[0].commit | Should -Be $fixture.Head.ToLowerInvariant()

            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.3.0-rc.1',$fixture.Head) | Out-Null
            $stable = New-ManifestPromotionPlan -Config $fixture.Config -Manifest $manifest -TargetChannel stable
            $stable.promotions[0].semanticVersion | Should -Be '1.3.0'
            $stable.promotions[0].tag | Should -Be 'app/v1.3.0'
            # Re-running the RC promotion must reuse the RC already on this commit.
            (New-ManifestPromotionPlan -Config $fixture.Config -Manifest $manifest -TargetChannel rc).promotions[0].semanticVersion | Should -Be '1.3.0-rc.1'
        } finally { Pop-Location }
    }
}

Describe 'Deployment guardrails' {
    It 'refuses a production deployment that cannot prove QA approval' {
        $manifestPath = Join-Path $TestDrive 'release-manifest.json'
        @{ schema = 'release-manifest/v1'; releaseId = 'beta-1'; candidateSha = ('a' * 40); components = @() } |
            ConvertTo-Json -Depth 8 | Set-Content $manifestPath
        { & "$PSScriptRoot/../Invoke-EnvironmentDeployment.ps1" -ConfigPath "$PSScriptRoot/../../../.releasepipeline.yml" -ManifestPath $manifestPath -Environment production -RequireApprovedRelease } |
            Should -Throw '*requires the QA-approved release manifest*'
    }

    It 'refuses a deployment that is handed something other than a release identity' {
        $planPath = Join-Path $TestDrive 'not-a-manifest.json'
        @{ schema = 'release-plan/v1' } | ConvertTo-Json | Set-Content $planPath
        { & "$PSScriptRoot/../Invoke-EnvironmentDeployment.ps1" -ConfigPath "$PSScriptRoot/../../../.releasepipeline.yml" -ManifestPath $planPath -Environment qa } |
            Should -Throw '*not a release manifest*'
    }

    It 'fails when application build output is present in a deployment job' {
        $configPath = Join-Path $TestDrive 'deploy-config.json'
        New-Item -ItemType Directory -Force -Path (Join-Path $TestDrive 'apps/app') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $TestDrive 'out/app') | Out-Null
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; package = @{ path = 'out/app' } } } } |
            ConvertTo-Json -Depth 8 | Set-Content $configPath
        try {
            Push-Location $TestDrive
            { & "$PSScriptRoot/../Assert-NoApplicationBuild.ps1" -ConfigPath $configPath -AdditionalPath @() } |
                Should -Throw '*never rebuild the application*'
            Remove-Item -Recurse -Force (Join-Path $TestDrive 'out')
            & "$PSScriptRoot/../Assert-NoApplicationBuild.ps1" -ConfigPath $configPath -AdditionalPath @() | Out-Null
        } finally { Pop-Location }
    }

    It 'rejects a deployment environment that declares a build step' {
        $configPath = Join-Path $TestDrive 'environment-config.json'
        New-Item -ItemType Directory -Force -Path (Join-Path $TestDrive 'apps/app') | Out-Null
        @{ versioning = @{ defaultBump = 'minor' }; branches = @{ main = @{ channel = 'stable' } }
           environments = @{ production = @{ build = @{ command = 'dotnet publish' } } }
           components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app' } } } |
            ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*must not define a build step*'
    }
}

Describe 'QA approval records' {
    It 'refuses to record an approval for a digest QA did not run' {
        $manifestPath = Join-Path $TestDrive 'approval-manifest.json'
        $deploymentPath = Join-Path $TestDrive 'approval-deployment.json'
        $candidate = 'a' * 40
        @{ schema = 'release-manifest/v1'; releaseId = 'beta-1'; candidateSha = $candidate; components = @(
            @{ component = 'api'; semanticVersion = '1.18.0-beta.1'; imageDigest = 'sha256:' + ('c' * 64) }
        ) } | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
        @{ schema = 'environment-deployment/v1'; environment = 'qa'; releaseId = 'beta-1'; candidateSha = $candidate; components = @(
            @{ component = 'api'; imageDigest = 'sha256:' + ('f' * 64) }
        ) } | ConvertTo-Json -Depth 8 | Set-Content $deploymentPath
        { & "$PSScriptRoot/../New-QaApprovalRecord.ps1" -ManifestPath $manifestPath -QaDeploymentPath $deploymentPath -OutputPath (Join-Path $TestDrive 'approved.json') } |
            Should -Throw '*Approval cannot be recorded*'
    }

    It 'records the approval against the SHA, release, and digest QA ran' {
        $manifestPath = Join-Path $TestDrive 'approval-manifest-ok.json'
        $deploymentPath = Join-Path $TestDrive 'approval-deployment-ok.json'
        $approvedPath = Join-Path $TestDrive 'approved-ok.json'
        $candidate = 'a' * 40
        $digest = 'sha256:' + ('c' * 64)
        @{ schema = 'release-manifest/v1'; releaseId = 'beta-1'; candidateSha = $candidate; channel = 'beta'; sourceBranch = 'dev'; repository = 'acme/orders'; ciRunId = '42'; generatedAt = '2026-01-01T00:00:00Z'; components = @(
            @{ component = 'api'; semanticVersion = '1.18.0-beta.1'; imageDigest = $digest }
        ) } | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
        @{ schema = 'environment-deployment/v1'; environment = 'qa'; releaseId = 'beta-1'; candidateSha = $candidate; components = @(
            @{ component = 'api'; imageDigest = $digest }
        ) } | ConvertTo-Json -Depth 8 | Set-Content $deploymentPath
        & "$PSScriptRoot/../New-QaApprovalRecord.ps1" -ManifestPath $manifestPath -QaDeploymentPath $deploymentPath -ApprovedBy 'release-manager' -OutputPath $approvedPath | Out-Null
        $approved = Get-Content $approvedPath -Raw | ConvertFrom-Json
        $approved.candidateSha | Should -Be $candidate
        $approved.components[0].imageDigest | Should -Be $digest
        $approved.qaApproval.approvedBy | Should -Be 'release-manager'
    }
}

