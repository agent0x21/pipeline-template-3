BeforeAll {
    Import-Module "$PSScriptRoot/../ReleasePipeline/ReleasePipeline.psd1" -Force
    . "$PSScriptRoot/Fixtures.ps1"
    . "$PSScriptRoot/../ReleasePipeline/ArtifactHandoff.ps1"
}

Describe 'Main-based release selection and versioning' {
    It 'uses the last stable baseline instead of the last commit' {
        $fixture = New-ReleaseFixtureRepository $TestDrive
        try {
            Push-Location $fixture.Repository
            Set-Content notes.txt 'unrelated last commit'
            Invoke-FixtureGit $fixture.Repository @('add','notes.txt') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Notes') | Out-Null
            $plan = New-ReleasePlan -Config $fixture.Config
            $plan.releases.Count | Should -Be 1
            $plan.releases[0].semanticVersion | Should -Be '1.3.0-rc.1'
        } finally { Pop-Location }
    }

    It 'keeps hotfix versions on an older reachable release line' {
        $fixture = New-ReleaseFixtureRepository $TestDrive
        try {
            Push-Location $fixture.Repository
            Invoke-FixtureGit $fixture.Repository @('tag','app/v3.0.0') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('checkout','-b','hotfix/1.2.4',$fixture.InitialCommit) | Out-Null
            Set-Content apps/app/source.txt 'production fix'
            Invoke-FixtureGit $fixture.Repository @('add','.') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Hotfix') | Out-Null
            (New-ReleasePlan -Config $fixture.Config -VersionBump patch).releases[0].semanticVersion | Should -Be '1.2.4-rc.1'
            { New-ReleasePlan -Config $fixture.Config -ExactVersions @{ app = '3.0.0' } } | Should -Throw '*already allocated*'
        } finally { Pop-Location }
    }

    It 'includes a component when its shared watched paths change' {
        $fixture = New-ReleaseFixtureRepository $TestDrive
        try {
            Push-Location $fixture.Repository
            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.3.0') | Out-Null
            New-Item -ItemType Directory packages/shared -Force | Out-Null
            Set-Content packages/shared/source.txt 'shared change'
            Invoke-FixtureGit $fixture.Repository @('add','.') | Out-Null
            Invoke-FixtureGit $fixture.Repository @('commit','-m','Shared change') | Out-Null
            $fixture.Config.components.app.watchPaths = @('packages/shared')
            (New-ReleasePlan -Config $fixture.Config).releases[0].semanticVersion | Should -Be '1.4.0-rc.1'
        } finally { Pop-Location }
    }

    It 'resolves main once and rejects off-main DEV commits' {
        $fixture = New-ReleaseFixtureRepository $TestDrive
        try {
            Push-Location $fixture.Repository
            Invoke-FixtureGit $fixture.Repository @('update-ref','refs/remotes/origin/main',$fixture.InitialCommit) | Out-Null
            (Resolve-ReleaseSource -SourceRef main -Intent dev).sha | Should -Be $fixture.InitialCommit
            { Resolve-ReleaseSource -SourceRef $fixture.Head -Intent dev } | Should -Throw '*not reachable*'
            { Resolve-ReleaseSource -SourceRef hotfix/test -Intent dev } | Should -Throw '*must originate from main*'
            { Resolve-ReleaseSource -SourceRef feature/test } | Should -Throw '*Source must*'
            Invoke-FixtureGit $fixture.Repository @('update-ref','refs/remotes/origin/hotfix/test',$fixture.Head) | Out-Null
            { Resolve-ReleaseSource -SourceRef hotfix/test } | Should -Throw '*require a baseline*'
            (Resolve-ReleaseSource -SourceRef hotfix/test -BaselineRelease app/v1.2.3).sha | Should -Be $fixture.Head
        } finally { Pop-Location }
    }

    It 'promotes a direct RC to stable at its source SHA without building' {
        $fixture = New-ReleaseFixtureRepository $TestDrive
        try {
            Push-Location $fixture.Repository
            Invoke-FixtureGit $fixture.Repository @('tag','app/v1.3.0-rc.1') | Out-Null
            $manifest = [pscustomobject]@{ releaseId = 'release/123'; candidateSha = $fixture.Head; components = @(
                [pscustomobject]@{ component = 'app'; tag = 'app/v1.3.0-rc.1'; semanticVersion = '1.3.0-rc.1'; imageDigest = $null; archiveSha256 = 'a' * 64 }
            ) }
            $promotion = New-ManifestPromotionPlan $fixture.Config $manifest
            $promotion.promotions[0].semanticVersion | Should -Be '1.3.0'
            $promotion.promotions[0].commit | Should -Be $fixture.Head
            $fixture.Config.components.app.tagPrefix = 'changed-on-main'
            (New-ManifestPromotionPlan $fixture.Config $manifest).promotions[0].tag | Should -Be 'app/v1.3.0'
            $manifest.candidateSha = $fixture.InitialCommit
            { New-ManifestPromotionPlan $fixture.Config $manifest } | Should -Throw '*does not match*'
        } finally { Pop-Location }
    }
}

Describe 'Manual artifact handoff identity' {
    BeforeEach {
        Set-Content "$TestDrive/web-v1.1.0-rc.1.zip" 'immutable web bytes'
        $manifest = [pscustomobject]@{
            schema = 'release-manifest/v2'; releaseId = 'release/123'; candidateSha = 'a' * 40; repository = 'owner/repo'
            components = @([pscustomobject]@{ component = 'web'; tag = 'web/v1.1.0-rc.1'; semanticVersion = '1.1.0-rc.1'; archiveAsset = 'web-v1.1.0-rc.1.zip'; archiveSha256 = (Get-FileHash "$TestDrive/web-v1.1.0-rc.1.zip").Hash.ToLowerInvariant(); image = $null; imageDigest = $null })
        }
    }
    It 'verifies ZIP-only components and rejects changed bytes' {
        { Test-HandoffArtifacts $manifest $TestDrive } | Should -Not -Throw
        Set-Content "$TestDrive/web-v1.1.0-rc.1.zip" 'tampered bytes'
        { Test-HandoffArtifacts $manifest $TestDrive } | Should -Throw '*checksum mismatch*'
    }
    It 'records preparation without claiming installation' {
        $handoff = New-ArtifactHandoff $manifest ('b' * 64) QA $TestDrive
        $handoff.status | Should -Be 'prepared'
        $handoff.installed | Should -BeFalse
        $handoff.components.Count | Should -Be 1
    }
    It 'rejects missing sign-off and changed manifests' {
        $approval = [pscustomobject]@{ schema = 'qa-signoff/v2'; environment = 'QA'; status = 'QA-approved'; releaseId = 'release/123'; candidateSha = 'a' * 40; manifestSha256 = 'b' * 64; reviewers = @('qa-tester'); evidenceUrl = 'https://api.github.com/evidence' }
        { Assert-QaSignoff $manifest ('b' * 64) $approval } | Should -Not -Throw
        { Assert-QaSignoff $manifest ('c' * 64) $approval } | Should -Throw '*does not match*'
        $approval.reviewers = @()
        { Assert-QaSignoff $manifest ('b' * 64) $approval } | Should -Throw '*reviewer evidence*'
    }
    It 'rejects duplicate components and unsafe asset paths' {
        $manifest.components += $manifest.components[0]
        { Assert-ReleaseManifestV2 $manifest } | Should -Throw '*Duplicate*'
        $manifest.components = @($manifest.components[0])
        $manifest.components[0].archiveAsset = '../outside.zip'
        { Assert-ReleaseManifestV2 $manifest } | Should -Throw '*Invalid ZIP asset*'
    }
}

Describe 'Workflow boundaries' {
    BeforeAll { Import-Module powershell-yaml }
    It 'parses every workflow and keeps DEV strictly manual' {
        $root = "$PSScriptRoot/../../../.github/workflows"
        foreach ($file in Get-ChildItem $root -Filter '*.yml') { { Get-Content $file.FullName -Raw | ConvertFrom-Yaml } | Should -Not -Throw }
        $dev = Get-Content "$root/dev-build.yml" -Raw | ConvertFrom-Yaml
        @($dev.on.Keys) | Should -Be @('workflow_dispatch')
        $dev.jobs.build.environment.name | Should -Be 'DEV'
        $dev.jobs.build.environment.ContainsKey('deployment') | Should -BeFalse
        $dev.jobs.build.environment.url | Should -Match '/actions/runs/'
    }
    It 'has no builds or branch updates in QA or production workflows' {
        foreach ($name in @('prepare-qa','promote-prod')) {
            $text = Get-Content "$PSScriptRoot/../../../.github/workflows/$name.yml" -Raw
            $text | Should -Not -Match 'dotnet (build|publish)|pnpm .*build|docker build|Update-PromotionBranch'
            $text | Should -Match 'releases/tag/\$\{\{ inputs.release_id \}\}'
        }
    }
}
