BeforeAll {
    . "$PSScriptRoot/../providers/github/ReleaseStore.ps1"
}
Describe 'Durable GitHub release store' {
    BeforeEach {
        $Repository = 'fixture/repository'
        $release = [pscustomobject]@{ id = 123; tag_name = 'release/456' }
    }
    It 'distinguishes missing assets from an incomplete release' {
        Mock Invoke-ReleaseApi { @() }
        Get-StoredAsset $release 'missing.zip' $TestDrive -Optional | Should -BeNullOrEmpty
        { Get-StoredAsset $release 'missing.zip' $TestDrive } | Should -Throw '*requires exactly one*'
    }
    It 'reuses identical bytes without uploading and rejects conflicting retries' {
        $path = Join-Path $TestDrive 'source.zip'
        $download = Join-Path $TestDrive 'download.zip'
        Set-Content $path 'same bytes'
        Copy-Item $path $download
        Mock Invoke-ReleaseApi { @([pscustomobject]@{ name = 'source.zip' }) }
        Mock Get-StoredAsset { $download }
        Mock Invoke-RestMethod { throw 'A retry must not upload existing bytes' }
        { Add-StoredAsset $release $path } | Should -Not -Throw
        Set-Content $download 'different bytes'
        { Add-StoredAsset $release $path } | Should -Throw '*different bytes*'
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'records the reviewer rather than the workflow requester' {
        Mock Invoke-ReleaseApi { @(
            [pscustomobject]@{ state = 'approved'; environments = @([pscustomobject]@{ name = 'QA' }); user = [pscustomobject]@{ login = 'actual-qa-reviewer' } },
            [pscustomobject]@{ state = 'approved'; environments = @([pscustomobject]@{ name = 'PROD' }); user = [pscustomobject]@{ login = 'production-reviewer' } }
        ) }
        $review = Get-EnvironmentReview QA -RunId 456
        $review.reviewers | Should -Be @('actual-qa-reviewer')
        $review.evidenceUrl | Should -Be 'https://api.github.com/repos/fixture/repository/actions/runs/456/approvals'
    }
    It 'rejects bypassed or rejected approval gates' {
        Mock Invoke-ReleaseApi { @([pscustomobject]@{ state = 'rejected'; environments = @([pscustomobject]@{ name = 'QA' }); user = [pscustomobject]@{ login = 'tester' } }) }
        { Get-EnvironmentReview QA -RunId 456 } | Should -Throw '*No GitHub reviewer evidence*'
    }
    It 'rejects downloads with a mismatched provider checksum' {
        Mock Invoke-ReleaseApi { @([pscustomobject]@{ name = 'source.zip'; url = 'https://api.github.com/asset'; digest = 'sha256:' + ('a' * 64) }) }
        Mock Invoke-WebRequest { param($OutFile) Set-Content $OutFile 'changed bytes' }
        { Get-StoredAsset $release 'source.zip' $TestDrive } | Should -Throw '*failed its GitHub checksum*'
    }
    It 'retries transient uploads.github.com failures and eventually succeeds' {
        $path = Join-Path $TestDrive 'asset.zip'
        Set-Content $path 'bytes'
        Mock Invoke-ReleaseApi { @() }
        Mock Start-Sleep {}
        $script:uploadAttempts = 0
        Mock Invoke-RestMethod {
            $script:uploadAttempts++
            if ($script:uploadAttempts -lt 3) {
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::ServiceUnavailable)
                $response.Headers.Add('X-GitHub-Request-Id', 'abc123')
                $ex = [System.Net.Http.HttpRequestException]::new('Error saving asset')
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
                throw $ex
            }
        }
        { Add-StoredAsset $release $path } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 3
    }
    It 'fails fast on a non-transient upload rejection without retrying' {
        $path = Join-Path $TestDrive 'asset2.zip'
        Set-Content $path 'bytes'
        Mock Invoke-ReleaseApi { @() }
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::UnprocessableEntity)
            $ex = [System.Net.Http.HttpRequestException]::new('Validation failed')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
            throw $ex
        }
        { Add-StoredAsset $release $path } | Should -Throw '*status=422*'
        Should -Invoke Invoke-RestMethod -Times 1
    }
    It 'round-trips values through a fenced JSON block' {
        $value = @{ releaseId = 'release/456'; manifestSha256 = ('a' * 64); installed = $false }
        $block = ConvertTo-FencedJsonBlock $value
        $block | Should -Match '```json'
        $body = @('Human-readable summary line.', '', $block) -join "`n"
        $parsed = ConvertFrom-FencedJsonBlock $body
        $parsed.releaseId | Should -Be 'release/456'
        $parsed.installed | Should -Be $false
    }
    It 'still parses a legacy body that is raw JSON with no fenced block' {
        $legacyBody = @{ releaseId = 'release/456'; manifestSha256 = ('a' * 64) } | ConvertTo-Json -Compress
        $parsed = ConvertFrom-FencedJsonBlock $legacyBody
        $parsed.releaseId | Should -Be 'release/456'
    }
    It 'peels annotated tags and rejects a changed source commit' {
        Mock Invoke-ReleaseApi {
            if ($Path -like 'git/ref/*') { [pscustomobject]@{ object = [pscustomobject]@{ type = 'tag'; sha = 'b' * 40 } } }
            else { [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = 'a' * 40 } } }
        }
        { Assert-StoredTagCommit 'web/v1.1.0-rc.1' ('a' * 40) } | Should -Not -Throw
        { Assert-StoredTagCommit 'web/v1.1.0-rc.1' ('c' * 40) } | Should -Throw '*does not identify*'
    }
}
