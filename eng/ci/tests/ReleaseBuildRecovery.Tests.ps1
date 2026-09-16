BeforeAll {
    . "$PSScriptRoot/Fixtures.ps1"
    # Simulate only the GitHub HTTP boundary; packaging, hashing, Git tags and
    # the provider orchestration run for real against a temporary repository.
    Add-Type -TypeDefinition @'
public class ReleaseFixtureNotFound : System.Exception {
    public System.Net.Http.HttpResponseMessage Response { get; } =
        new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.NotFound);
}
'@
}
Describe 'RC publication recovery integration' {
    It 'resumes a partial component publication without rebuilding or changing the manifest' {
        $fixture = New-ReleaseFixtureRepository $TestDrive
        $remote = Join-Path $TestDrive 'release-remote.git'
        Invoke-FixtureGit $fixture.Repository @('init','--bare',$remote) | Out-Null
        Invoke-FixtureGit $fixture.Repository @('remote','add','origin',$remote) | Out-Null
        $global:ReleaseHttpFixture = @{}
        $global:ReleaseHttpFixture.store = @{}
        $global:ReleaseHttpFixture.assetStore = @{}
        $global:ReleaseHttpFixture.nextAssetId = 0
        $global:ReleaseHttpFixture.failOnce = $true
        $global:ReleaseHttpFixture.storeRoot = Join-Path $TestDrive 'http-assets'
        New-Item -ItemType Directory $global:ReleaseHttpFixture.storeRoot | Out-Null
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body, $InFile)
            $uriObject = [uri]$Uri
            $path = $uriObject.AbsolutePath -replace '^/repos/fixture/repository/', ''
            if ($uriObject.Host -eq 'uploads.github.com') {
                $releaseId = [int]([regex]::Match($path, 'releases/(\d+)/assets').Groups[1].Value)
                $name = [uri]::UnescapeDataString(($uriObject.Query -replace '^\?name=', '' -split '&')[0])
                $release = $global:ReleaseHttpFixture.store[$releaseId]
                if ($release.tag_name -like 'app/*' -and $name.EndsWith('.zip') -and $global:ReleaseHttpFixture.failOnce) {
                    $global:ReleaseHttpFixture.failOnce = $false
                    throw 'Simulated component publication interruption'
                }
                $global:ReleaseHttpFixture.nextAssetId++
                $assetId = $global:ReleaseHttpFixture.nextAssetId
                $assetPath = Join-Path $global:ReleaseHttpFixture.storeRoot "$assetId.bin"
                Copy-Item -LiteralPath $InFile -Destination $assetPath
                $global:ReleaseHttpFixture.assetStore[$assetId] = $assetPath
                $asset = [pscustomobject]@{ id = $assetId; name = $name; url = "https://api.github.com/assets/$assetId"; digest = "sha256:$((Get-FileHash $assetPath).Hash.ToLowerInvariant())" }
                $release.assets += $asset
                return $asset
            }
            if ($path -like 'releases/tags/*') {
                $tag = [uri]::UnescapeDataString($path.Substring('releases/tags/'.Length))
                $match = @($global:ReleaseHttpFixture.store.Values | Where-Object tag_name -eq $tag)
                if (-not $match.Count) { throw [ReleaseFixtureNotFound]::new() }
                return $match[0]
            }
            if ($path -like 'git/ref/tags/*') {
                $tag = [uri]::UnescapeDataString($path.Substring('git/ref/tags/'.Length))
                $sha = Invoke-FixtureGit (Get-Location).Path @('rev-parse',"$tag^{commit}") | Select-Object -First 1
                return [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = $sha } }
            }
            if ($path -like 'actions/runs/*/approvals') {
                $environment = if ($path -like '*/456/*') { 'QA' } else { 'PROD' }
                return @([pscustomobject]@{ state = 'approved'; environments = @([pscustomobject]@{ name = $environment }); user = [pscustomobject]@{ login = "$environment-reviewer" } })
            }
            if ($path -eq 'actions/runs/456') {
                return [pscustomobject]@{ path = '.github/workflows/prepare-qa.yml'; head_branch = 'main'; conclusion = 'success' }
            }
            if ($path -eq 'releases' -and $Method -eq 'POST') {
                $record = $Body | ConvertFrom-Json
                $record | Add-Member id ($global:ReleaseHttpFixture.store.Count + 1)
                $record | Add-Member assets @()
                $global:ReleaseHttpFixture.store[$record.id] = $record
                return $record
            }
            if ($path -match '^releases/(\d+)/assets$') { return $global:ReleaseHttpFixture.store[[int]$Matches[1]].assets }
            if ($path -match '^releases/(\d+)$' -and $Method -eq 'PATCH') {
                $record = $global:ReleaseHttpFixture.store[[int]$Matches[1]]
                $changes = $Body | ConvertFrom-Json -AsHashtable
                foreach ($key in $changes.Keys) { $record | Add-Member $key $changes[$key] -Force }
                return $record
            }
            throw "Unexpected fixture HTTP request: $Method $Uri"
        }
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            $assetId = [int](([uri]$Uri).Segments[-1])
            Copy-Item -LiteralPath $global:ReleaseHttpFixture.assetStore[$assetId] -Destination $OutFile -Force
        }
        $previousToken = $env:GH_TOKEN
        $previousRun = $env:GITHUB_RUN_ID
        $previousSummary = $env:GITHUB_STEP_SUMMARY
        $previousOutput = $env:GITHUB_OUTPUT
        try {
            $env:GH_TOKEN = 'fixture-token'
            $env:GITHUB_STEP_SUMMARY = $null
            $env:GITHUB_OUTPUT = $null
            Push-Location $fixture.Repository
            $fixture.Config.components.app.type = 'node'
            $fixture.Config.components.app.build = @{ command = "New-Item -ItemType Directory out -Force | Out-Null; Add-Content build-count.txt 'built'; Set-Content out/app.txt 'immutable application bytes'" }
            $fixture.Config.components.app.package = @{ path = 'out' }
            $fixture.Config | ConvertTo-Json -Depth 12 | Set-Content config.json
            $arguments = @{ ConfigPath = 'config.json'; ExpectedSha = $fixture.Head; Repository = 'fixture/repository'; RunId = '123' }
            { & "$PSScriptRoot/../providers/github/Invoke-ReleaseBuild.ps1" @arguments } | Should -Throw '*Simulated component publication interruption*'
            $manifestHash = (Get-FileHash '.release-work/release-manifest.json').Hash
            { & "$PSScriptRoot/../providers/github/Invoke-ReleaseBuild.ps1" @arguments } | Should -Not -Throw
            @(Get-Content build-count.txt).Count | Should -Be 1
            (Get-FileHash '.release-work/release-manifest.json').Hash | Should -Be $manifestHash
            @($global:ReleaseHttpFixture.store.Values | Where-Object tag_name -eq 'release/123')[0].draft | Should -BeFalse
            (Invoke-FixtureGit $fixture.Repository @('rev-parse','app/v1.3.0-rc.1^{commit}')) | Should -Be $fixture.Head
            $handoffArguments = @{ ReleaseId = 'release/123'; Repository = 'fixture/repository'; ConfigPath = 'config.json' }
            & "$PSScriptRoot/../providers/github/Invoke-ReleaseHandoff.ps1" @handoffArguments -Operation PrepareQA
            (Get-Content '.release-handoff/handoff.json' -Raw | ConvertFrom-Json).installed | Should -BeFalse
            $env:GITHUB_RUN_ID = '456'
            & "$PSScriptRoot/../providers/github/Invoke-ReleaseHandoff.ps1" @handoffArguments -Operation ApproveQA -ExpectedManifestSha256 $manifestHash
            $env:GITHUB_RUN_ID = '789'
            & "$PSScriptRoot/../providers/github/Invoke-ReleaseHandoff.ps1" @handoffArguments -Operation PromotePROD -QaRunId '456'
            # Retry production too: the stable identity and original package bytes remain unchanged.
            & "$PSScriptRoot/../providers/github/Invoke-ReleaseHandoff.ps1" @handoffArguments -Operation PromotePROD -QaRunId '456'
            @(Get-Content build-count.txt).Count | Should -Be 1
            (Invoke-FixtureGit $fixture.Repository @('rev-parse','app/v1.3.0^{commit}')) | Should -Be $fixture.Head
            $stableRelease = @($global:ReleaseHttpFixture.store.Values | Where-Object tag_name -eq 'app/v1.3.0')[0]
            $stableRelease.draft | Should -BeFalse
            $stableAsset = @($stableRelease.assets | Where-Object name -eq 'app-v1.3.0.zip')[0]
            $candidateAsset = @($global:ReleaseHttpFixture.store.Values | Where-Object tag_name -eq 'app/v1.3.0-rc.1')[0].assets | Where-Object name -eq 'app-v1.3.0-rc.1.zip'
            $stableAsset.digest | Should -Be $candidateAsset.digest
        } finally {
            Pop-Location
            $env:GH_TOKEN = $previousToken
            $env:GITHUB_RUN_ID = $previousRun
            $env:GITHUB_STEP_SUMMARY = $previousSummary
            $env:GITHUB_OUTPUT = $previousOutput
            Remove-Variable -Name ReleaseHttpFixture -Scope Global
        }
    }
}
