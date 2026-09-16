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
    It 'peels annotated tags and rejects a changed source commit' {
        Mock Invoke-ReleaseApi {
            if ($Path -like 'git/ref/*') { [pscustomobject]@{ object = [pscustomobject]@{ type = 'tag'; sha = 'b' * 40 } } }
            else { [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = 'a' * 40 } } }
        }
        { Assert-StoredTagCommit 'web/v1.1.0-rc.1' ('a' * 40) } | Should -Not -Throw
        { Assert-StoredTagCommit 'web/v1.1.0-rc.1' ('c' * 40) } | Should -Throw '*does not identify*'
    }
}
