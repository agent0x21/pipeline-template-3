Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Hashtable([object] $Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-Hashtable $Value[$key] }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    if (@($Value.PSObject.Properties).Count -gt 0 -and $Value -isnot [string]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-Hashtable $property.Value }
        return $result
    }
    return $Value
}

function Test-ReleaseConfigPath {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$ConfigDirectory, [Parameter(Mandatory)][string]$Description)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Description must not be empty." }
    if ([IO.Path]::IsPathRooted($Value)) { throw "$Description must be relative to the configuration file." }

    $root = [IO.Path]::GetFullPath($ConfigDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $Value))
    $rootWithSeparator = "$root$([IO.Path]::DirectorySeparatorChar)"
    if (-not $candidate.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must remain within the configuration directory."
    }
    return $candidate
}

function Test-ReleaseConfig {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ConfigDirectory)
    if (-not $Config.components -or @($Config.components.Keys).Count -eq 0) { throw 'Configuration must define at least one component.' }
    if (-not $Config.versioning) { throw 'Configuration must define versioning.' }
    if (-not $Config.versioning.defaultBump) { $Config.versioning.defaultBump = 'minor' }
    if ($Config.versioning.defaultBump -notin @('major','minor','patch')) { throw 'versioning.defaultBump must be major, minor, or patch.' }
    if (-not $Config.branches -or @($Config.branches.Keys).Count -eq 0) { throw 'Configuration must define at least one branch channel.' }

    foreach ($branch in $Config.branches.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$branch)) { throw 'Branch names must not be empty.' }
        $branchConfig = $Config.branches[$branch]
        $channel = if ($branchConfig -is [System.Collections.IDictionary] -and $branchConfig.ContainsKey('channel')) { [string]$branchConfig.channel } else { '' }
        if ($channel -notin @('stable','beta','rc')) { throw "Branch '$branch' must specify stable, beta, or rc as its channel." }
    }

    $tagPrefixes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Config.components.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) { throw 'Component names must not be empty.' }
        $component = $Config.components[$name]
        if ($component -isnot [System.Collections.IDictionary]) { throw "Component '$name' must be a mapping." }
        foreach ($required in @('path','tagPrefix')) { if (-not $component[$required]) { throw "Component '$name' requires '$required'." } }
        $tagPrefix = [string]$component.tagPrefix
        if ($tagPrefix -notmatch '^[^/\\\s]+(?:/[^/\\\s]+)*$') { throw "Component '$name' has an invalid tagPrefix '$tagPrefix'." }
        if (-not $tagPrefixes.Add($tagPrefix)) { throw "Component '$name' duplicates tagPrefix '$tagPrefix'." }

        $componentPath = Test-ReleaseConfigPath -Value ([string]$component.path) -ConfigDirectory $ConfigDirectory -Description "Component '$name' path"
        if (-not (Test-Path -LiteralPath $componentPath -PathType Container)) { throw "Component '$name' path does not exist: $($component.path)" }
        if ($component.ContainsKey('build') -and $component.build -is [System.Collections.IDictionary] -and $component.build.ContainsKey('solution') -and $component.build.solution) {
            $solutionPath = Test-ReleaseConfigPath -Value ([string]$component.build.solution) -ConfigDirectory $ConfigDirectory -Description "Component '$name' build.solution"
            if (-not (Test-Path -LiteralPath $solutionPath -PathType Leaf)) { throw "Component '$name' build.solution does not exist: $($component.build.solution)" }
        }
    }

    foreach ($name in $Config.components.Keys) {
        $dependencies = if ($Config.components[$name].ContainsKey('dependencies')) { @($Config.components[$name].dependencies) } else { @() }
        foreach ($dependency in $dependencies) {
            $dependencyName = [string]$dependency
            if (-not $Config.components.ContainsKey($dependencyName)) { throw "Component '$name' references missing dependency '$dependencyName'." }
            if ($dependencyName -eq $name) { throw "Component '$name' cannot depend on itself." }
        }
    }

    $remainingDependencies = @{}
    foreach ($name in $Config.components.Keys) {
        $remainingDependencies[$name] = if ($Config.components[$name].ContainsKey('dependencies')) { @($Config.components[$name].dependencies).Count } else { 0 }
    }
    $ready = [Collections.Generic.Queue[string]]::new()
    foreach ($name in $remainingDependencies.Keys) { if ($remainingDependencies[$name] -eq 0) { $ready.Enqueue($name) } }
    $processed = 0
    while ($ready.Count -gt 0) {
        $resolved = $ready.Dequeue(); $processed++
        foreach ($name in $Config.components.Keys) {
            $dependencies = if ($Config.components[$name].ContainsKey('dependencies')) { @($Config.components[$name].dependencies) } else { @() }
            if ($dependencies -contains $resolved) {
                $remainingDependencies[$name]--
                if ($remainingDependencies[$name] -eq 0) { $ready.Enqueue($name) }
            }
        }
    }
    if ($processed -ne $Config.components.Count) { throw 'Component dependency graph contains a cycle.' }
}

function Import-ReleaseConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string] $Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    $config = if ([IO.Path]::GetExtension($Path) -eq '.json') {
        $raw | ConvertFrom-Json -AsHashtable
    } elseif (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        $raw | ConvertFrom-Yaml
    } else {
        throw 'YAML support is unavailable. Install the powershell-yaml module or provide a JSON configuration.'
    }
    $config = ConvertTo-Hashtable $config
    Test-ReleaseConfig -Config $config -ConfigDirectory (Split-Path -Parent (Resolve-Path -LiteralPath $Path))
    return $config
}

function Get-ReleaseChannel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config, [Parameter(Mandatory)][string] $Branch)
    $branchConfig = $Config.branches[$Branch]
    if ($branchConfig -and $branchConfig.channel) { return [string]$branchConfig.channel }
    return $null
}

function Get-Git([string[]] $Arguments) {
    $safeDirectory = (Get-Location).Path
    $output = & git '-c' "safe.directory=$safeDirectory" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
    return @($output | ForEach-Object { [string]$_ })
}

function ConvertFrom-SemVer([Parameter(Mandatory)][string] $Version) {
    $match = [regex]::Match($Version, '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<channel>beta|rc)\.(?<sequence>[1-9]\d*))?$')
    if (-not $match.Success) { throw "Invalid semantic version: $Version" }
    [pscustomobject]@{ Major = [int]$match.Groups['major'].Value; Minor = [int]$match.Groups['minor'].Value; Patch = [int]$match.Groups['patch'].Value; Channel = $match.Groups['channel'].Value; Sequence = if ($match.Groups['sequence'].Success) { [int]$match.Groups['sequence'].Value } else { $null }; Text = $Version }
}

function ConvertTo-SemVer([int]$Major, [int]$Minor, [int]$Patch, [string]$Channel, [int]$Sequence) {
    $core = "$Major.$Minor.$Patch"
    if ($Channel) { return "$core-$Channel.$Sequence" }
    return $core
}

function Get-ComponentVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Component)
    $prefix = [string]$Component.tagPrefix
    $versions = foreach ($tag in (Get-Git @('tag','--list',"$prefix/v*"))) {
        if ($tag -match "^$([regex]::Escape($prefix))/v(?<version>.+)$") {
            try { $version = ConvertFrom-SemVer $Matches.version; if (-not $version.Channel) { $version } } catch { }
        }
    }
    if (-not $versions) { return $null }
    return $versions | Sort-Object Major,Minor,Patch -Descending | Select-Object -First 1
}

function Get-ChangedComponents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config, [string] $BaseRef = 'HEAD~1', [string] $Commit = 'HEAD')
    $paths = Get-Git @('diff','--name-only',"$BaseRef...$Commit")
    $changed = [Collections.Generic.HashSet[string]]::new()
    foreach ($name in $Config.components.Keys) {
        $componentPath = ([string]$Config.components[$name].path).TrimEnd('/','\')
        if ($paths | Where-Object { $_ -eq $componentPath -or $_.StartsWith("$componentPath/") -or $_.StartsWith("$componentPath\") }) { [void]$changed.Add($name) }
    }
    return @($changed)
}

function Get-AffectedComponents([hashtable]$Config, [string[]]$Changed) {
    $affected = [Collections.Generic.HashSet[string]]::new()
    foreach ($name in $Changed) { [void]$affected.Add($name) }
    $added = $true
    while ($added) {
        $added = $false
        foreach ($name in $Config.components.Keys) {
            $dependencies = if ($Config.components[$name].ContainsKey('dependencies')) { @($Config.components[$name].dependencies) } else { @() }
            if (-not $affected.Contains($name) -and ($dependencies | Where-Object { $affected.Contains([string]$_) })) {
                [void]$affected.Add($name); $added = $true
            }
        }
    }
    return @($affected)
}

function Resolve-Bump([string]$Name, [hashtable]$Config, [string]$WorkflowBump, [hashtable]$Overrides) {
    if ($Overrides -and $Overrides[$Name]) { return @{ Type = [string]$Overrides[$Name]; Source = 'component' } }
    if ($WorkflowBump) { return @{ Type = $WorkflowBump; Source = 'workflow' } }
    return @{ Type = [string]$Config.versioning.defaultBump; Source = 'configuration' }
}

function Compare-CoreVersion([object]$Left, [object]$Right) {
    foreach ($field in @('Major','Minor','Patch')) {
        if ($Left.$field -ne $Right.$field) { return [Math]::Sign($Left.$field - $Right.$field) }
    }
    return 0
}

function Get-ReleaseForCommit {
    param([Parameter(Mandatory)][hashtable]$Component, [Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$Channel)
    $prefix = [string]$Component.tagPrefix
    $matches = foreach ($tag in (Get-Git @('tag','--list',"$prefix/v*"))) {
        if ($tag -notmatch "^$([regex]::Escape($prefix))/v(?<version>.+)$") { continue }
        try { $version = ConvertFrom-SemVer $Matches.version } catch { continue }
        if (($Channel -eq 'stable' -and $version.Channel) -or ($Channel -ne 'stable' -and $version.Channel -ne $Channel)) { continue }
        $tagCommit = Get-Git @('rev-list','-n','1',$tag) | Select-Object -First 1
        if ($tagCommit -eq $Commit) { [pscustomobject]@{ Tag = $tag; Version = $version } }
    }
    if (@($matches).Count -gt 1) { throw "Multiple $Channel release tags for component '$prefix' point to commit '$Commit'." }
    return @($matches) | Select-Object -First 1
}

function New-ArtifactPromotionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ProvenancePath,
        [Parameter(Mandatory)][ValidateSet('rc','stable')][string]$TargetChannel
    )
    $provenance = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
    $sourceReleases = @($provenance.plan.releases)
    $sourceArtifacts = @($provenance.artifacts)
    if ($sourceReleases.Count -eq 0) { throw 'Artifact provenance does not contain any releases to promote.' }
    if ($sourceArtifacts.Count -eq 0) { throw 'Artifact provenance does not contain any immutable artifacts to promote.' }

    $promotions = foreach ($source in $sourceReleases) {
        $componentName = [string]$source.component
        if (-not $Config.components.ContainsKey($componentName)) { throw "Promotion source references unknown component '$componentName'." }
        $component = $Config.components[$componentName]
        $sourceVersion = ConvertFrom-SemVer ([string]$source.semanticVersion)
        $sourceChannel = [string]$source.channel
        if ($sourceChannel -ne $sourceVersion.Channel) { throw "Promotion source channel does not match semantic version for '$componentName'." }
        if (($TargetChannel -eq 'rc' -and $sourceChannel -ne 'beta') -or ($TargetChannel -eq 'stable' -and $sourceChannel -ne 'rc')) {
            throw "Cannot promote '$componentName' from '$sourceChannel' to '$TargetChannel'. Promotion must follow beta -> rc -> stable."
        }

        $artifact = @($sourceArtifacts | Where-Object { $_.component -eq $componentName -and $_.semanticVersion -eq $source.semanticVersion })
        if ($artifact.Count -ne 1) { throw "Promotion source must contain exactly one artifact for '$componentName' version '$($source.semanticVersion)'." }
        $sha256 = [string]$artifact[0].sha256
        if ($sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Promotion artifact for '$componentName' does not contain a valid SHA-256 digest." }

        $targetVersion = if ($TargetChannel -eq 'stable') {
            ConvertTo-SemVer $sourceVersion.Major $sourceVersion.Minor $sourceVersion.Patch '' 0
        } else {
            $baseVersion = ConvertTo-SemVer $sourceVersion.Major $sourceVersion.Minor $sourceVersion.Patch '' 0
            $tagPrefix = [string]$component.tagPrefix
            $sequence = @(Get-Git @('tag','--list',"$tagPrefix/v$baseVersion-rc.*") | ForEach-Object {
                if ($_ -match '-rc\.(?<n>\d+)$') { [int]$Matches.n }
            } | Measure-Object -Maximum).Maximum
            if (-not $sequence) { $sequence = 0 }
            ConvertTo-SemVer $sourceVersion.Major $sourceVersion.Minor $sourceVersion.Patch 'rc' ($sequence + 1)
        }
        [pscustomobject]@{
            component = $componentName
            commit = [string]$source.commit
            channel = $TargetChannel
            semanticVersion = $targetVersion
            tag = "$($component.tagPrefix)/v$targetVersion"
            sourceChannel = $sourceChannel
            sourceSemanticVersion = [string]$source.semanticVersion
            sourceTag = [string]$source.tag
            sourceArtifactPath = [string]$artifact[0].path
            sourceSha256 = $sha256.ToLowerInvariant()
        }
    }
    [pscustomobject]@{
        generatedAt = [DateTime]::UtcNow.ToString('o')
        sourceProvenance = (Resolve-Path -LiteralPath $ProvenancePath).Path
        targetChannel = $TargetChannel
        promotions = @($promotions)
    }
}

function New-ReleasePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('major','minor','patch')][string]$VersionBump,
        [hashtable]$ComponentOverrides = @{}, [hashtable]$ExactVersions = @{},
        [Parameter(Mandatory)][string]$Branch, [string]$BaseRef = 'HEAD~1', [string]$Commit = 'HEAD',
        [string]$CiRunId = '', [string]$Repository = ''
    )
    $channel = Get-ReleaseChannel $Config $Branch
    if (-not $channel) { return [pscustomobject]@{ generatedAt = [DateTime]::UtcNow.ToString('o'); commit = (Get-Git @('rev-parse',$Commit) | Select-Object -First 1); branch = $Branch; releases = @() } }
    $commitSha = Get-Git @('rev-parse',$Commit) | Select-Object -First 1
    $names = Get-AffectedComponents $Config (Get-ChangedComponents $Config $BaseRef $Commit)
    $releases = foreach ($name in $names) {
        $component = $Config.components[$name]; $current = Get-ComponentVersion $component
        $bump = Resolve-Bump $name $Config $VersionBump $ComponentOverrides
        if ($bump.Type -notin @('major','minor','patch')) { throw "Invalid bump for '$name': $($bump.Type)" }
        $existingRelease = Get-ReleaseForCommit -Component $component -Commit $commitSha -Channel $channel
        $versionText = if ($existingRelease) { $existingRelease.Version.Text } elseif ($ExactVersions[$name]) { [string]$ExactVersions[$name] } else {
            $base = if ($current) { $current } else { ConvertFrom-SemVer ([string]$(if ($component.ContainsKey('initialVersion')) { $component.initialVersion } else { '0.0.0' })) }
            $major = $base.Major; $minor = $base.Minor; $patch = $base.Patch
            if ($bump.Type -eq 'major') { $major++; $minor = 0; $patch = 0 } elseif ($bump.Type -eq 'minor') { $minor++; $patch = 0 } else { $patch++ }
            ConvertTo-SemVer $major $minor $patch '' 0
        }
        $parsed = ConvertFrom-SemVer $versionText
        if (-not $existingRelease -and $current -and (Compare-CoreVersion $parsed $current) -le 0 -and -not $ExactVersions[$name]) { throw "Calculated version for '$name' is not newer than current version." }
        if (-not $existingRelease -and $ExactVersions[$name] -and $current -and (Compare-CoreVersion $parsed $current) -le 0) { throw "Exact version for '$name' must be greater than current stable version." }
        $sequence = 0
        if (-not $existingRelease -and $channel -ne 'stable' -and -not ($ExactVersions[$name] -and $parsed.Channel)) {
            $tagPrefix = [string]$component.tagPrefix
            $tagPattern = "$tagPrefix/v$versionText-$channel.*"
            $sequence = @(Get-Git @('tag','--list',$tagPattern) | ForEach-Object { if ($_ -match "-$channel\.(?<n>\d+)$") { [int]$Matches.n } } | Measure-Object -Maximum).Maximum
            if (-not $sequence) { $sequence = 0 }; $sequence++
            $versionText = "$versionText-$channel.$sequence"
        }
        if ($ExactVersions[$name] -and $parsed.Channel -and $parsed.Channel -ne $channel) { throw "Exact version channel for '$name' does not match branch channel '$channel'." }
        [pscustomobject]@{ component = $name; path = [string]$component.path; componentType = if ($component.ContainsKey('type')) { [string]$component.type } else { '' }; artifactPath = if ($component.ContainsKey('package') -and $component.package.ContainsKey('path')) { [string]$component.package.path } else { [string]$component.path }; semanticVersion = $versionText; tag = if ($existingRelease) { $existingRelease.Tag } else { "$($component.tagPrefix)/v$versionText" }; channel = $channel; bump = $bump.Type; bumpSource = if ($existingRelease) { 'rerun' } elseif ($ExactVersions[$name]) { 'exact-version' } else { $bump.Source }; currentVersion = if ($current) { $current.Text } else { $null }; commit = $commitSha; ciRunId = $CiRunId; repository = $Repository; buildCommand = if ($component.ContainsKey('build') -and $component.build.ContainsKey('command')) { [string]$component.build.command } else { '' }; buildSolution = if ($component.ContainsKey('build') -and $component.build.ContainsKey('solution')) { [string]$component.build.solution } else { '' }; buildMsbuildPath = if ($component.ContainsKey('build') -and $component.build.ContainsKey('msbuildPath')) { [string]$component.build.msbuildPath } else { '' }; buildConfiguration = if ($component.ContainsKey('build') -and $component.build.ContainsKey('configuration')) { [string]$component.build.configuration } else { 'Release' }; testCommand = if ($component.ContainsKey('test') -and $component.test.ContainsKey('command')) { [string]$component.test.command } else { '' } }
    }
    return [pscustomobject]@{ generatedAt = [DateTime]::UtcNow.ToString('o'); branch = $Branch; channel = $channel; commit = $commitSha; releases = @($releases) }
}

function Invoke-ComponentPackage {
    [CmdletBinding()] param([Parameter(Mandatory)][pscustomobject]$Release, [Parameter(Mandatory)][string]$OutputDirectory)
    $componentOutput = Join-Path $OutputDirectory $Release.component
    New-Item -ItemType Directory -Force -Path $componentOutput | Out-Null
    $zip = Join-Path $componentOutput "$($Release.component)-v$($Release.semanticVersion).zip"
    $artifactPath = if ($Release.PSObject.Properties.Name -contains 'artifactPath') { [string]$Release.artifactPath } else { [string]$Release.path }
    $inputPath = Join-Path (Get-Location) $artifactPath
    if (-not (Test-Path -LiteralPath $inputPath)) { throw "Artifact path not found for '$($Release.component)': $inputPath" }
    Compress-Archive -Path $inputPath -DestinationPath $zip -Force
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    [pscustomobject]@{ path = $zip; sha256 = $hash; component = $Release.component; semanticVersion = $Release.semanticVersion }
}

function Find-MSBuild {
    [CmdletBinding()]
    param([string]$PreferredPath, [switch]$UseVsWhere)
    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath -PathType Leaf)) { return (Resolve-Path -LiteralPath $PreferredPath).Path }
    if (-not $UseVsWhere) {
        $command = Get-Command msbuild.exe -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    $vswhere = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    $vswherePath = if ($vswhere) { $vswhere.Source } else { $null }
    if (-not $vswherePath -and ${env:ProgramFiles(x86)}) {
        $defaultVsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $defaultVsWhere -PathType Leaf) { $vswherePath = $defaultVsWhere }
    }
    if ($vswherePath) {
        $candidate = & $vswherePath '-latest' '-products' '*' '-requires' 'Microsoft.Component.MSBuild' '-find' 'MSBuild\\**\\Bin\\MSBuild.exe' 2>$null | Select-Object -First 1
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'MSBuild.exe was not found. Install Visual Studio Build Tools with Microsoft.Component.MSBuild or provide build.msbuildPath.'
}

function Invoke-ComponentBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Release)
    $buildCommand = if ($Release.PSObject.Properties.Name -contains 'buildCommand') { [string]$Release.buildCommand } else { '' }
    $componentType = if ($Release.PSObject.Properties.Name -contains 'componentType') { [string]$Release.componentType } else { '' }
    $buildSolution = if ($Release.PSObject.Properties.Name -contains 'buildSolution') { [string]$Release.buildSolution } else { '' }
    $buildMsbuildPath = if ($Release.PSObject.Properties.Name -contains 'buildMsbuildPath') { [string]$Release.buildMsbuildPath } else { '' }
    $buildConfiguration = if ($Release.PSObject.Properties.Name -contains 'buildConfiguration') { [string]$Release.buildConfiguration } else { 'Release' }
    if ($buildCommand) {
        & pwsh -NoProfile -NonInteractive -Command $buildCommand 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Build failed for $($Release.component)." }
        return
    }
    if ($componentType -eq 'legacy-dotnet-framework') {
        if (-not $buildSolution) { throw "Legacy component '$($Release.component)' requires build.solution or build.command." }
        $msbuild = Find-MSBuild $buildMsbuildPath
        & $msbuild $buildSolution "/p:Configuration=$buildConfiguration" '/m' 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "MSBuild failed for $($Release.component)." }
        return
    }
    throw "No build adapter is configured for component '$($Release.component)' of type '$($Release.componentType)'."
}

function Get-RemoteTagCommit {
    param([Parameter(Mandatory)][string]$Tag)
    $safeDirectory = (Get-Location).Path
    $output = & git '-c' "safe.directory=$safeDirectory" ls-remote --tags origin "refs/tags/$Tag" "refs/tags/$Tag^{}" 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $entries = foreach ($line in $output) {
        $parts = ([string]$line -split '\s+', 2)
        if ($parts.Count -eq 2) { [pscustomobject]@{ Sha = $parts[0]; Reference = $parts[1] } }
    }
    $peeled = @($entries | Where-Object { $_.Reference -eq "refs/tags/$Tag^{}" } | Select-Object -First 1)
    if ($peeled) { return $peeled.Sha }
    $direct = @($entries | Where-Object { $_.Reference -eq "refs/tags/$Tag" } | Select-Object -First 1)
    if ($direct) { return $direct.Sha }
    return $null
}

function Remove-CreatedReleaseTag {
    param([Parameter(Mandatory)][pscustomobject]$Release)
    $localCommit = Get-Git @('rev-list','-n','1',$Release.tag) | Select-Object -First 1
    if ($localCommit -ne $Release.commit) { throw "Refusing to remove release tag '$($Release.tag)' because it no longer points to the planned commit." }
    Get-Git @('tag','-d',$Release.tag) | Out-Null
}

function New-ReleaseTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Release,
        [switch]$Push,
        [ValidateRange(1, 10)][int]$PushAttempts = 3
    )
    $existing = @(Get-Git @('tag','--list',$Release.tag))
    if ($existing) {
        $tagCommit = Get-Git @('rev-list','-n','1',$Release.tag) | Select-Object -First 1
        if ($tagCommit -eq $Release.commit) { return [pscustomobject]@{ tag = $Release.tag; status = 'already-exists' } }
        throw "Tag '$($Release.tag)' already exists on another commit."
    }
    & git tag -a $Release.tag $Release.commit -m "Release $($Release.component) $($Release.semanticVersion)"
    if ($LASTEXITCODE -ne 0) { throw "Unable to create tag '$($Release.tag)'." }
    if ($Push) {
        $safeDirectory = (Get-Location).Path
        for ($attempt = 1; $attempt -le $PushAttempts; $attempt++) {
            $pushOutput = & git '-c' "safe.directory=$safeDirectory" push --atomic origin $Release.tag 2>&1
            if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ tag = $Release.tag; status = 'created' } }

            $remoteCommit = Get-RemoteTagCommit -Tag $Release.tag
            if ($remoteCommit) {
                Remove-CreatedReleaseTag -Release $Release
                if ($remoteCommit -eq $Release.commit) { return [pscustomobject]@{ tag = $Release.tag; status = 'already-exists' } }
                throw "Tag '$($Release.tag)' was created on another commit while it was being pushed. Recreate the release plan before retrying."
            }
            if ($attempt -lt $PushAttempts) { Start-Sleep -Milliseconds (250 * $attempt) }
        }
        Remove-CreatedReleaseTag -Release $Release
        throw "Unable to push tag '$($Release.tag)' after $PushAttempts attempts: $($pushOutput -join ' ')"
    }
    [pscustomobject]@{ tag = $Release.tag; status = 'created' }
}

Export-ModuleMember -Function Import-ReleaseConfig,Get-ReleaseChannel,Get-ComponentVersion,New-ReleasePlan,New-ArtifactPromotionPlan,Invoke-ComponentPackage,Invoke-ComponentBuild,New-ReleaseTag
