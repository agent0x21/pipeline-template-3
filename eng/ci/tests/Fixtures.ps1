function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & git -c "safe.directory=$Repository" -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture git command failed: git $($Arguments -join ' '): $($output -join ' ')" }
    return @($output | ForEach-Object { [string]$_ })
}

function New-ReleaseFixtureRepository {
    param([Parameter(Mandatory)][string]$Root, [ValidateSet('stable','prerelease','legacy','rerun','conflict','bootstrap')][string]$Scenario = 'stable')

    $repository = Join-Path $Root "$Scenario-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path (Join-Path $repository 'apps/app') | Out-Null
    Set-Content -LiteralPath (Join-Path $repository 'apps/app/source.txt') -Value 'initial'
    Invoke-FixtureGit $repository @('init') | Out-Null
    Invoke-FixtureGit $repository @('config','user.email','release-fixture@example.invalid') | Out-Null
    Invoke-FixtureGit $repository @('config','user.name','Release Fixture') | Out-Null
    Invoke-FixtureGit $repository @('add','.') | Out-Null
    Invoke-FixtureGit $repository @('commit','-m','Initial fixture') | Out-Null
    $initialCommit = Invoke-FixtureGit $repository @('rev-parse','HEAD') | Select-Object -First 1

    if ($Scenario -eq 'bootstrap') {
        return @{ Repository = $repository; InitialCommit = $initialCommit; Head = $initialCommit; Config = @{
            versioning = @{ defaultBump = 'minor' }
            branches = @{ main = @{ channel = 'stable' }; dev = @{ channel = 'beta' }; qa = @{ channel = 'rc' } }
            components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app' } }
        } }
    }

    Invoke-FixtureGit $repository @('tag','app/v1.2.3',$initialCommit) | Out-Null
    switch ($Scenario) {
        'prerelease' {
            Invoke-FixtureGit $repository @('tag','app/v1.3.0-beta.1',$initialCommit) | Out-Null
            Invoke-FixtureGit $repository @('tag','app/v1.3.0-beta.2',$initialCommit) | Out-Null
            Invoke-FixtureGit $repository @('tag','app/v1.3.0-rc.1',$initialCommit) | Out-Null
        }
        'legacy' {
            Invoke-FixtureGit $repository @('tag','app/legacy-release',$initialCommit) | Out-Null
            Invoke-FixtureGit $repository @('tag','other/v9.9.9',$initialCommit) | Out-Null
        }
    }

    Set-Content -LiteralPath (Join-Path $repository 'apps/app/source.txt') -Value 'changed'
    Invoke-FixtureGit $repository @('add','.') | Out-Null
    Invoke-FixtureGit $repository @('commit','-m','Fixture change') | Out-Null
    $head = Invoke-FixtureGit $repository @('rev-parse','HEAD') | Select-Object -First 1
    if ($Scenario -eq 'rerun') { Invoke-FixtureGit $repository @('tag','app/v1.3.0-beta.1',$head) | Out-Null }
    if ($Scenario -eq 'conflict') { Invoke-FixtureGit $repository @('tag','app/v1.3.0-beta.1',$initialCommit) | Out-Null }

    @{ Repository = $repository; InitialCommit = $initialCommit; Head = $head; Config = @{
        versioning = @{ defaultBump = 'minor' }
        branches = @{ main = @{ channel = 'stable' }; dev = @{ channel = 'beta' }; qa = @{ channel = 'rc' } }
        components = @{ app = @{ path = 'apps/app'; tagPrefix = 'app' } }
    } }
}
