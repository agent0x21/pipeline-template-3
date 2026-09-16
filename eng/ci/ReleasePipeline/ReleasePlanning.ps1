# Explicit release intent. Branches describe source history, never environments.
function Resolve-ReleaseSource {
    [CmdletBinding()]
    param([string]$SourceRef = 'main', [ValidateSet('dev','rc')][string]$Intent = 'rc', [string]$BaselineRelease = '')
    if ($SourceRef -notmatch '^(main|[0-9a-fA-F]{40}|(?:hotfix|release)/[A-Za-z0-9._/-]+)$') {
        throw 'Source must be main, a full SHA reachable from main, or a temporary hotfix/release branch.'
    }
    $temporary = $SourceRef -match '^(hotfix|release)/'
    if ($Intent -eq 'dev' -and $temporary) { throw 'DEV artifacts must originate from main.' }
    $ref = if ($SourceRef -eq 'main' -or $temporary) { "refs/remotes/origin/$SourceRef" } else { $SourceRef }
    $sha = (Get-Git @('rev-parse','--verify',"$ref^{commit}") | Select-Object -First 1).Trim()
    $ancestor = if ($temporary) {
        if (-not $BaselineRelease -or $BaselineRelease -notmatch '^(release/[A-Za-z0-9._-]+|[^/]+/v\d+\.\d+\.\d+)$') { throw 'Temporary release sources require a baseline release-set or stable component tag.' }
        (Get-Git @('rev-parse','--verify',"refs/tags/$BaselineRelease^{commit}") | Select-Object -First 1).Trim()
    } else { $sha }
    $descendant = if ($temporary) { $sha } else { 'refs/remotes/origin/main' }
    & git -c "safe.directory=$((Get-Location).Path)" merge-base --is-ancestor $ancestor $descendant
    if ($LASTEXITCODE -ne 0) { throw 'Source does not descend from the baseline or is not reachable from main.' }
    [pscustomobject]@{ sha = $sha; sourceRef = $SourceRef; baselineRelease = $BaselineRelease; hotfix = $SourceRef.StartsWith('hotfix/') }
}

function Get-ReleaseBaseline {
    param([hashtable]$Component, [string]$Commit = 'HEAD')
    $prefix = [string]$Component.tagPrefix
    $versions = foreach ($tag in (Get-Git @('tag','--merged',$Commit,'--list',"$prefix/v*"))) {
        if ($tag -match "^$([regex]::Escape($prefix))/v(?<version>\d+\.\d+\.\d+)$") {
            $version = ConvertFrom-SemVer $Matches.version
            [pscustomobject]@{ tag = $tag; version = $version }
        }
    }
    $versions | Sort-Object { $_.version.Major }, { $_.version.Minor }, { $_.version.Patch } -Descending | Select-Object -First 1
}

function New-ReleasePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('major','minor','patch')][string]$VersionBump,
        [hashtable]$ComponentOverrides = @{}, [hashtable]$ExactVersions = @{},
        [string]$Branch = 'main', [string]$BaseRef = '', [string]$Commit = 'HEAD', [switch]$ReleaseAll,
        [ValidateSet('rc')][string]$Channel = 'rc', [string]$CiRunId = '', [string]$Repository = ''
    )
    $commitSha = (Get-Git @('rev-parse',"$Commit^{commit}") | Select-Object -First 1).Trim()
    foreach ($key in @($ComponentOverrides.Keys) + @($ExactVersions.Keys)) {
        if (-not $Config.components.ContainsKey($key)) { throw "Unknown component override '$key'." }
    }
    $baselines = @{}; $changed = @()
    foreach ($name in $Config.components.Keys) {
        $component = $Config.components[$name]
        $baseline = Get-ReleaseBaseline -Component $component -Commit $commitSha
        $baselines[$name] = $baseline
        $base = if ($BaseRef) { $BaseRef } elseif ($baseline) { $baseline.tag } else { '' }
        $paths = if ($base) { @(Get-Git @('diff','--name-only',$base,$commitSha)) } else { @(Get-Git @('ls-tree','-r','--name-only',$commitSha)) }
        $watched = @([string]$component.path)
        if ($component.ContainsKey('watchPaths')) { $watched += @($component.watchPaths) }
        if ($Config.ContainsKey('watchPaths')) { $watched += @($Config.watchPaths) }
        $matchesPath = @($paths | Where-Object {
            $path = $_
            @($watched | Where-Object { $path -eq $_ -or $path.StartsWith("$($_.TrimEnd('/'))/") }).Count -gt 0
        }).Count -gt 0
        if ($ReleaseAll -or $matchesPath) { $changed += $name }
    }
    $releases = foreach ($name in (Get-AffectedComponents $Config $changed | Sort-Object)) {
        $component = $Config.components[$name]; $baseline = $baselines[$name]
        $current = if ($baseline) { $baseline.version } else { $null }
        $bump = Resolve-Bump $name $Config $VersionBump $ComponentOverrides
        if ($bump.Type -notin @('major','minor','patch')) { throw "Invalid bump for '$name'." }
        $existing = Get-ReleaseForCommit -Component $component -Commit $commitSha -Channel rc
        if ($existing -and $ExactVersions[$name]) {
            $requested = ConvertFrom-SemVer $ExactVersions[$name]
            if ((Compare-CoreVersion $existing.Version $requested) -ne 0 -or ($requested.Channel -and $requested.Text -ne $existing.Version.Text)) { throw "Existing RC for '$name' conflicts with the requested version." }
        }
        $versionText = if ($existing) { $existing.Version.Text } elseif ($ExactVersions[$name]) { [string]$ExactVersions[$name] } else {
            $base = if ($current) { $current } else { ConvertFrom-SemVer $(if ($component.ContainsKey('initialVersion')) { $component.initialVersion } else { '0.0.0' }) }
            $major = $base.Major; $minor = $base.Minor; $patch = $base.Patch
            switch ($bump.Type) { major { $major++; $minor = 0; $patch = 0 }; minor { $minor++; $patch = 0 }; patch { $patch++ } }
            "$major.$minor.$patch"
        }
        $parsed = ConvertFrom-SemVer $versionText
        if ($parsed.Channel -and $parsed.Channel -ne 'rc') { throw 'New releases must use the RC channel.' }
        if (-not $existing -and $current -and (Compare-CoreVersion $parsed $current) -le 0) { throw "Version for '$name' must exceed its reachable stable baseline." }
        $core = "$($parsed.Major).$($parsed.Minor).$($parsed.Patch)"
        if (-not $existing -and -not $parsed.Channel) {
            $numbers = @(Get-Git @('tag','--list',"$($component.tagPrefix)/v$core-rc.*") | ForEach-Object { if ($_ -match '-rc\.(\d+)$') { [int]$Matches[1] } })
            $next = if ($numbers.Count) { ($numbers | Measure-Object -Maximum).Maximum + 1 } else { 1 }
            $versionText = "$core-rc.$next"
        }
        $tag = "$($component.tagPrefix)/v$versionText"
        if (-not $existing -and @(Get-Git @('tag','--list',"$($component.tagPrefix)/v$core")).Count) { throw "Stable version '$core' is already allocated for '$name'." }
        if (-not $existing -and @(Get-Git @('tag','--list',$tag)).Count) { throw "RC tag '$tag' is already allocated." }
        [pscustomobject]@{
            component = $name; path = $component.path; componentType = if ($component.ContainsKey('type')) { [string]$component.type } else { '' }
            artifactPath = if ($component.ContainsKey('package')) { $component.package.path } else { $component.path }
            semanticVersion = $versionText; tag = $tag; channel = 'rc'; bump = $bump.Type
            bumpSource = if ($existing) { 'rerun' } elseif ($ExactVersions[$name]) { 'exact-version' } else { $bump.Source }
            currentVersion = if ($current) { $current.Text } else { $null }; baselineTag = if ($baseline) { $baseline.tag } else { $null }
            commit = $commitSha; ciRunId = $CiRunId; repository = $Repository
            buildCommand = if ($component.ContainsKey('build') -and $component.build.ContainsKey('command')) { $component.build.command } else { '' }
            buildSolution = if ($component.ContainsKey('build') -and $component.build.ContainsKey('solution')) { $component.build.solution } else { '' }
            buildMsbuildPath = if ($component.ContainsKey('build') -and $component.build.ContainsKey('msbuildPath')) { $component.build.msbuildPath } else { '' }
            buildConfiguration = if ($component.ContainsKey('build') -and $component.build.ContainsKey('configuration')) { $component.build.configuration } else { 'Release' }
            testCommand = if ($component.ContainsKey('test')) { $component.test.command } else { '' }
        }
    }
    [pscustomobject]@{ generatedAt = [DateTime]::UtcNow.ToString('o'); branch = $Branch; channel = 'rc'; commit = $commitSha; releases = @($releases) }
}

function New-ManifestPromotionPlan {
    [CmdletBinding()]
    param([hashtable]$Config, [object]$Manifest, [ValidateSet('stable')][string]$TargetChannel = 'stable')
    if (@($Manifest.components).Count -eq 0) { throw 'Empty release manifest.' }
    $promotions = foreach ($entry in $Manifest.components) {
        $source = ConvertFrom-SemVer $entry.semanticVersion
        if ($source.Channel -ne 'rc') { throw 'Stable promotion requires an RC artifact.' }
        $sha = Get-Git @('rev-parse',"$($entry.tag)^{commit}") | Select-Object -First 1
        if ($sha -ne $Manifest.candidateSha) { throw 'RC tag does not match the manifest commit.' }
        $core = "$($source.Major).$($source.Minor).$($source.Patch)"
        # The selected artifact owns its tag namespace, even if main's config changes during QA.
        $stableTag = [string]$entry.tag -replace '-rc\.\d+$', ''
        if (@(Get-Git @('tag','--list',$stableTag)).Count) {
            $stableSha = Get-Git @('rev-parse',"$stableTag^{commit}") | Select-Object -First 1
            if ($stableSha -ne $Manifest.candidateSha) { throw "Stable tag '$stableTag' already belongs to another commit." }
        }
        [pscustomobject]@{
            component = $entry.component; commit = $Manifest.candidateSha; channel = 'stable'
            semanticVersion = $core; tag = $stableTag
            sourceChannel = 'rc'; sourceSemanticVersion = $entry.semanticVersion; sourceTag = $entry.tag
            sourceImageDigest = $entry.imageDigest; sourceArchiveSha256 = $entry.archiveSha256
        }
    }
    [pscustomobject]@{ releaseId = $Manifest.releaseId; candidateSha = $Manifest.candidateSha; targetChannel = 'stable'; promotions = @($promotions) }
}
