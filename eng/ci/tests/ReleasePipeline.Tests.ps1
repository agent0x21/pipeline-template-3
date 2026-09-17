BeforeAll {
    Import-Module "$PSScriptRoot/../ReleasePipeline/ReleasePipeline.psd1" -Force
    . "$PSScriptRoot/Fixtures.ps1"
}
Describe 'Release configuration and channels' {
    It 'loads the sample configuration with minor as the default' {
        $config = Import-ReleaseConfig "$PSScriptRoot/../../../.releasepipeline.yml"
        $config.versioning.defaultBump | Should -Be 'minor'
        $config.ContainsKey('branches') | Should -BeFalse
        $config.environments.Keys | Should -Contain 'PROD'
    }
}

Describe 'Release planning' {
    It 'gives component overrides precedence over workflow overrides' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{}; }
        $bump = & (Get-Module ReleasePipeline) { param($cfg) Resolve-Bump 'app' $cfg 'patch' @{ app = 'major' } } $config
        $bump.Type | Should -Be 'major'; $bump.Source | Should -Be 'component'
    }

    It 'propagates affected components through dependencies without changing unrelated components' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{
            common = @{ path = 'src/common'; tagPrefix = 'common' }
            api = @{ path = 'src/api'; tagPrefix = 'api'; dependencies = @('common') }
            web = @{ path = 'src/web'; tagPrefix = 'web' }
        }; }
        $affected = & (Get-Module ReleasePipeline) { param($cfg) Get-AffectedComponents $cfg @('common') } $config
        @($affected | Sort-Object) | Should -Be @('api','common')
    }

    It 'uses the configured artifact path in a release plan' {
        $config = @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'src/app'; tagPrefix = 'app'; package = @{ path = 'out/app' } } }; }
        Mock -ModuleName ReleasePipeline Get-Git { if ($Arguments[0] -eq 'rev-parse') { 'abc123' } else { @() } }
        Mock -ModuleName ReleasePipeline Get-ChangedComponents { @('app') }
        $plan = New-ReleasePlan -Config $config -Branch main -Commit HEAD -ReleaseAll
        $plan.releases[0].artifactPath | Should -Be 'out/app'
    }
}

Describe 'Release configuration validation' {
    BeforeEach {
        $configPath = Join-Path $TestDrive 'release-config.json'
        New-Item -ItemType Directory -Force -Path (Join-Path $TestDrive 'apps/app') | Out-Null
    }

    It 'rejects a missing dependency' {
        @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; dependencies = @('missing') } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*missing dependency*'
    }

    It 'rejects dependency cycles, duplicate prefixes, and paths outside the repository' {
        @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'shared'; dependencies = @('worker') }; worker = @{ path = 'apps/app'; tagPrefix = 'shared'; dependencies = @('app') } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*duplicates tagPrefix*'

        @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = '../outside'; tagPrefix = 'app' } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
        { Import-ReleaseConfig $configPath } | Should -Throw '*within the configuration directory*'

        @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; dependencies = @('worker') }; worker = @{ path = 'apps/app'; tagPrefix = 'worker'; dependencies = @('app') } } } | ConvertTo-Json -Depth 8 | Set-Content $configPath
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
            $plan.releases[0].semanticVersion | Should -Be '0.1.0-rc.1'
            $plan.releases[0].tag | Should -Be 'app/v0.1.0-rc.1'
        } finally { Pop-Location }
    }

    It 'calculates stable and prerelease versions from namespaced tags' {
        $stable = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $prerelease = New-ReleaseFixtureRepository -Root $TestDrive -Scenario prerelease
        try {
            Push-Location $stable.Repository
            (New-ReleasePlan -Config $stable.Config -Branch main -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0-rc.1'
            $exactPlan = New-ReleasePlan -Config $stable.Config -Branch main -BaseRef HEAD~1 -ExactVersions @{ app = '1.4.0' }
            $exactPlan.releases[0].semanticVersion | Should -Be '1.4.0-rc.1'
            $exactPlan.releases[0].bumpSource | Should -Be 'exact-version'
        } finally { Pop-Location }
        try {
            Push-Location $prerelease.Repository
            (New-ReleasePlan -Config $prerelease.Config -Branch dev -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0-rc.2'
            (New-ReleasePlan -Config $prerelease.Config -Branch qa -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0-rc.2'
            { New-ReleasePlan -Config $prerelease.Config -Branch dev -BaseRef HEAD~1 -ExactVersions @{ app = '1.2.3' } } | Should -Throw '*reachable stable baseline*'
            { New-ReleasePlan -Config $prerelease.Config -Branch qa -BaseRef HEAD~1 -ExactVersions @{ app = '1.2.0' } } | Should -Throw '*reachable stable baseline*'
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
            (New-ReleasePlan -Config $legacy.Config -Branch main -BaseRef HEAD~1).releases[0].semanticVersion | Should -Be '1.3.0-rc.1'
        } finally { Pop-Location }
        try {
            Push-Location $rerun.Repository
            $plan = New-ReleasePlan -Config $rerun.Config -Branch dev -BaseRef HEAD~1
            $plan.releases[0].semanticVersion | Should -Be '1.3.0-rc.1'
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
            $plan.releases[0].semanticVersion | Should -Be '1.3.0-rc.1'
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

Describe 'GitHub release asset upload retries' {
    BeforeAll {
        function New-GitHubAssetUploadFixture {
            param([Parameter(Mandatory)]$TestDrive)
            $bundlePath = Join-Path $TestDrive 'bundle'
            $artifactPath = Join-Path $bundlePath 'artifacts'
            $assetPath = Join-Path $artifactPath 'web/web-v1.0.0.zip'
            New-Item -ItemType Directory -Force -Path (Split-Path $assetPath) | Out-Null
            Set-Content -LiteralPath $assetPath -Value 'web artifact'
            $provenancePath = Join-Path $artifactPath 'provenance.json'
            $planPath = Join-Path $bundlePath 'release-plan.json'
            $hash = (Get-FileHash $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $releasePlan = [pscustomobject]@{ releases = @(
                [pscustomobject]@{ component = 'web'; semanticVersion = '1.0.0'; channel = 'stable'; tag = 'web/v1.0.0'; commit = 'abc123' }
            ) }
            [pscustomobject]@{
                plan = $releasePlan
                artifacts = @(
                    [pscustomobject]@{ component = 'web'; semanticVersion = '1.0.0'; path = 'D:\original\artifacts\web\web-v1.0.0.zip'; sha256 = $hash; artifactType = 'zip' }
                )
            } | ConvertTo-Json -Depth 12 | Set-Content $provenancePath
            $releasePlan | ConvertTo-Json -Depth 12 | Set-Content $planPath
            [pscustomobject]@{ PlanPath = $planPath; ProvenancePath = $provenancePath; Sha256 = $hash }
        }

        function New-GitHubUploadFailure {
            param([int]$StatusCode, [string]$Message = 'transient failure', [string]$Body)
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$StatusCode)
            if ($Body) { $response.Content = [System.Net.Http.StringContent]::new($Body) }
            $ex = [System.Net.Http.HttpRequestException]::new($Message)
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
            $ex
        }

        function Invoke-PublishScript {
            param($PlanPath, $ProvenancePath)
            $oldRepository = $env:GITHUB_REPOSITORY; $oldToken = $env:GITHUB_TOKEN
            try {
                $env:GITHUB_REPOSITORY = 'example/repository'; $env:GITHUB_TOKEN = 'test-token'
                & "$PSScriptRoot/../providers/github/Publish-GitHubReleaseAssets.ps1" -PlanPath $PlanPath -ProvenancePath $ProvenancePath
            } finally {
                $env:GITHUB_REPOSITORY = $oldRepository; $env:GITHUB_TOKEN = $oldToken
            }
        }
    }

    It 'retries a transient upload failure and succeeds' {
        $fixture = New-GitHubAssetUploadFixture -TestDrive $TestDrive
        Mock Start-Sleep {}
        $global:ghUploadAttempts = 0
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get' -and $Uri -like '*/tags/*') { return [pscustomobject]@{ id = 1; tag_name = 'web/v1.0.0'; assets = @() } }
            if ($Method -eq 'Get' -and $Uri -like '*/assets?per_page=100') { return @() }
            if ($Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*') {
                $global:ghUploadAttempts++
                if ($global:ghUploadAttempts -lt 3) { throw (New-GitHubUploadFailure -StatusCode 503 -Message 'Error creating asset temp dir' -Body '{"message":"Error creating asset temp dir"}') }
                return $null
            }
            return $null
        }

        try {
            { Invoke-PublishScript -PlanPath $fixture.PlanPath -ProvenancePath $fixture.ProvenancePath } | Should -Not -Throw
            $global:ghUploadAttempts | Should -Be 3
            Should -Invoke Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*' } -Times 3 -Exactly
        } finally {
            Remove-Item -LiteralPath Variable:\ghUploadAttempts -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exhausts retries and reports the release tag, asset name, status, body, and attempt count' {
        $fixture = New-GitHubAssetUploadFixture -TestDrive $TestDrive
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get' -and $Uri -like '*/tags/*') { return [pscustomobject]@{ id = 1; tag_name = 'web/v1.0.0'; assets = @() } }
            if ($Method -eq 'Get' -and $Uri -like '*/assets?per_page=100') { return @() }
            if ($Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*') { throw (New-GitHubUploadFailure -StatusCode 503 -Message 'Error creating asset temp dir' -Body '{"message":"Error creating asset temp dir"}') }
            return $null
        }

        { Invoke-PublishScript -PlanPath $fixture.PlanPath -ProvenancePath $fixture.ProvenancePath } |
            Should -Throw "*web-v1.0.0.zip*web/v1.0.0*attempt 5 of 5*status=503*Error creating asset temp dir*"
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*' } -Times 5 -Exactly
    }

    It 'fails fast on a permanent authentication/validation failure without retrying' {
        $fixture = New-GitHubAssetUploadFixture -TestDrive $TestDrive
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get' -and $Uri -like '*/tags/*') { return [pscustomobject]@{ id = 1; tag_name = 'web/v1.0.0'; assets = @() } }
            if ($Method -eq 'Get' -and $Uri -like '*/assets?per_page=100') { return @() }
            if ($Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*') { throw (New-GitHubUploadFailure -StatusCode 401 -Message 'Bad credentials' -Body '{"message":"Bad credentials"}') }
            return $null
        }

        { Invoke-PublishScript -PlanPath $fixture.PlanPath -ProvenancePath $fixture.ProvenancePath } | Should -Throw '*status=401*'
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*' } -Times 1 -Exactly
    }

    It 'reconciles an ambiguous failure when the asset already exists with a matching digest' {
        $fixture = New-GitHubAssetUploadFixture -TestDrive $TestDrive
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get' -and $Uri -like '*/tags/*') { return [pscustomobject]@{ id = 1; tag_name = 'web/v1.0.0'; assets = @() } }
            if ($Method -eq 'Get' -and $Uri -like '*/assets?per_page=100') {
                return @([pscustomobject]@{ name = 'web-v1.0.0.zip'; digest = "sha256:$($fixture.Sha256)" })
            }
            if ($Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*') {
                # Simulate a dropped connection: the request may well have reached
                # GitHub and created the asset, but the client never saw a response.
                $ex = [System.Net.Http.HttpRequestException]::new('The connection was reset')
                throw $ex
            }
            return $null
        }

        { Invoke-PublishScript -PlanPath $fixture.PlanPath -ProvenancePath $fixture.ProvenancePath } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*' } -Times 1 -Exactly
    }

    It 'throws when a reconciled asset exists with a different digest' {
        $fixture = New-GitHubAssetUploadFixture -TestDrive $TestDrive
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get' -and $Uri -like '*/tags/*') { return [pscustomobject]@{ id = 1; tag_name = 'web/v1.0.0'; assets = @() } }
            if ($Method -eq 'Get' -and $Uri -like '*/assets?per_page=100') {
                return @([pscustomobject]@{ name = 'web-v1.0.0.zip'; digest = 'sha256:' + ('0' * 64) })
            }
            if ($Method -eq 'Post' -and $Uri -like '*name=web-v1.0.0.zip*') {
                $ex = [System.Net.Http.HttpRequestException]::new('The connection was reset')
                throw $ex
            }
            return $null
        }

        { Invoke-PublishScript -PlanPath $fixture.PlanPath -ProvenancePath $fixture.ProvenancePath } | Should -Throw '*different or unavailable SHA-256 digest*'
    }
}

Describe 'GitHub release asset upload retry/backoff helpers' {
    BeforeAll {
        $script:helperPlanPath = Join-Path $TestDrive 'helpers-empty-plan.json'
        $script:helperProvenancePath = Join-Path $TestDrive 'helpers-empty-provenance.json'
        [pscustomobject]@{ releases = @() } | ConvertTo-Json -Depth 4 | Set-Content $script:helperPlanPath
        [pscustomobject]@{ artifacts = @() } | ConvertTo-Json -Depth 4 | Set-Content $script:helperProvenancePath
        . "$PSScriptRoot/../providers/github/Publish-GitHubReleaseAssets.ps1" -PlanPath $script:helperPlanPath -ProvenancePath $script:helperProvenancePath -Repository 'example/repository' -Token 'test-token'
    }

    It 'treats missing status codes and 408/429/5xx as retryable' {
        Test-GitHubApiErrorRetryable -StatusCode $null | Should -BeTrue
        Test-GitHubApiErrorRetryable -StatusCode 408 | Should -BeTrue
        Test-GitHubApiErrorRetryable -StatusCode 429 | Should -BeTrue
        Test-GitHubApiErrorRetryable -StatusCode 500 | Should -BeTrue
        Test-GitHubApiErrorRetryable -StatusCode 503 | Should -BeTrue
    }

    It 'treats authentication, authorization, and validation failures as non-retryable' {
        Test-GitHubApiErrorRetryable -StatusCode 401 | Should -BeFalse
        Test-GitHubApiErrorRetryable -StatusCode 403 | Should -BeFalse
        Test-GitHubApiErrorRetryable -StatusCode 404 | Should -BeFalse
        Test-GitHubApiErrorRetryable -StatusCode 422 | Should -BeFalse
    }

    It 'uses exponential backoff when no Retry-After is present' {
        Get-GitHubApiRetryDelaySeconds -Attempt 1 -RetryAfterSeconds $null | Should -Be 1
        Get-GitHubApiRetryDelaySeconds -Attempt 2 -RetryAfterSeconds $null | Should -Be 2
        Get-GitHubApiRetryDelaySeconds -Attempt 3 -RetryAfterSeconds $null | Should -Be 4
    }

    It 'honors Retry-After over exponential backoff' {
        Get-GitHubApiRetryDelaySeconds -Attempt 1 -RetryAfterSeconds 30 | Should -Be 30
        Get-GitHubApiRetryDelaySeconds -Attempt 4 -RetryAfterSeconds 7 | Should -Be 7
    }

    It 'extracts status code, Retry-After, and body from an HTTP error response' {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
        $response.Headers.Add('Retry-After', '12')
        $response.Content = [System.Net.Http.StringContent]::new('{"message":"rate limited"}')
        $ex = [System.Net.Http.HttpRequestException]::new('Too Many Requests')
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
        $errorRecord = $null
        try { throw $ex } catch { $errorRecord = $_ }

        $detail = Get-GitHubApiErrorDetail -ErrorRecord $errorRecord
        $detail.StatusCode | Should -Be 429
        $detail.RetryAfterSeconds | Should -Be 12
        $detail.Body | Should -Match 'rate limited'
    }

    It 'falls back to the exception message when no response is available' {
        $errorRecord = $null
        try { throw [System.Net.Http.HttpRequestException]::new('DNS resolution failed') } catch { $errorRecord = $_ }

        $detail = Get-GitHubApiErrorDetail -ErrorRecord $errorRecord
        $detail.StatusCode | Should -BeNullOrEmpty
        $detail.Body | Should -Match 'DNS resolution failed'
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
        @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; publishing = @{ adapter = 'npm'; endpoint = 'https://registry.example.invalid'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
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
        @{ versioning = @{ defaultBump = 'minor' }; components = @{ api = @{ path = 'apps/api'; tagPrefix = 'api'; publishing = @{ adapter = 'container'; image = 'example.invalid/api'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
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
            @{ component = 'api'; adapter = 'npm'; semanticVersion = '1.2.0'; artifactPath = $artifactPath; endpoint = 'https://registry.example.invalid'; oidc = $true; sha256 = (Get-FileHash $artifactPath).Hash.ToLowerInvariant() },
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
        @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; publishing = @{ adapter = 'npm'; endpoint = 'https://registry.example.invalid'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
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
        @{ versioning = @{ defaultBump = 'minor' }; components = @{ api = @{ path = 'apps/api'; tagPrefix = 'api'; publishing = @{ adapter = 'container'; image = 'example.invalid/api'; oidc = $true } } } } | ConvertTo-Json -Depth 12 | Set-Content $configPath
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
        @{ versioning = @{ defaultBump = 'minor' }; components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app'; package = @{ path = 'out/app' } } } } |
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
        @{ versioning = @{ defaultBump = 'minor' };
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


Describe 'Development build component resolution' {
    It 'resolves the requested component definition without corrupting it through the -Component parameter' {
        # Regression test for a case-insensitive variable collision: the script's
        # -Component parameter is [string[]], and a same-named local variable used to
        # be assigned the component's hashtable inside the selection loop. Because
        # PowerShell variable names are case-insensitive, that reassignment silently
        # coerced the hashtable into a string array instead of failing at the point
        # of assignment, and every property/key access on it then failed far from the
        # real cause ("The property 'path' cannot be found on this object.").
        # Passing -Component with at least one entry is what triggers the collision.
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $configPath = Join-Path $fixture.Repository 'release-config.json'
        $config = $fixture.Config
        # A trivial, dependency-free build command keeps this test independent of any
        # real toolchain while still exercising the exact component-resolution path
        # that failed (Invoke-ComponentBuild only runs once $build is built correctly).
        $config.components.app.build = @{ command = "Write-Host 'build ok'" }
        $config | ConvertTo-Json -Depth 12 | Set-Content $configPath
        $outputDir = Join-Path $fixture.Repository 'dev-artifacts'
        $outputPath = Join-Path $fixture.Repository 'development-build.json'
        try {
            Push-Location $fixture.Repository
            & "$PSScriptRoot/../Invoke-DevelopmentBuild.ps1" -ConfigPath $configPath -ExpectedSha $fixture.Head -Branch 'dev/feature' -Component @('app') -OutputDirectory $outputDir -OutputPath $outputPath | Out-Null
            $record = Get-Content $outputPath -Raw | ConvertFrom-Json
            $record.isReleaseCandidate | Should -BeFalse
            $record.gitSha | Should -Be $fixture.Head.ToLowerInvariant()
            $record.components.Count | Should -Be 1
            $record.components[0].component | Should -Be 'app'
            $record.components[0].archivePath | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $record.components[0].archivePath) | Should -BeTrue
        } finally { Pop-Location }
    }

    It 'still fails past component resolution for a component with no configured build adapter, proving resolution (not the build step) was the original failure' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $configPath = Join-Path $fixture.Repository 'release-config.json'
        $fixture.Config | ConvertTo-Json -Depth 12 | Set-Content $configPath
        try {
            Push-Location $fixture.Repository
            { & "$PSScriptRoot/../Invoke-DevelopmentBuild.ps1" -ConfigPath $configPath -ExpectedSha $fixture.Head -Branch 'dev/feature' -Component @('app') } |
                Should -Throw '*No build adapter is configured*'
        } finally { Pop-Location }
    }

    It 'rejects an unknown requested component by name instead of a property error' {
        $fixture = New-ReleaseFixtureRepository -Root $TestDrive -Scenario stable
        $configPath = Join-Path $fixture.Repository 'release-config.json'
        $fixture.Config | ConvertTo-Json -Depth 12 | Set-Content $configPath
        try {
            Push-Location $fixture.Repository
            { & "$PSScriptRoot/../Invoke-DevelopmentBuild.ps1" -ConfigPath $configPath -ExpectedSha $fixture.Head -Branch 'dev/feature' -Component @('does-not-exist') } |
                Should -Throw "*Unknown component 'does-not-exist'*"
        } finally { Pop-Location }
    }
}
