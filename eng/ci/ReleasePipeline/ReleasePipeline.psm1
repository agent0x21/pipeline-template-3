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
    if ($Config.ContainsKey('branches')) { throw 'Branch channels are retired. Pass explicit release intent instead.' }

    if ($Config.ContainsKey('environments') -and $Config.environments) {
        if ($Config.environments -isnot [System.Collections.IDictionary]) { throw 'Configuration environments must be a mapping.' }
        foreach ($environment in $Config.environments.Keys) {
            $environmentConfig = $Config.environments[$environment]
            if ($environmentConfig -isnot [System.Collections.IDictionary]) { throw "Environment '$environment' must be a mapping." }
            if ($environmentConfig.ContainsKey('aliasTag') -and [string]::IsNullOrWhiteSpace([string]$environmentConfig.aliasTag)) { throw "Environment '$environment' aliasTag must not be empty." }
            # A deployment target may never build the application: it receives an
            # already-published immutable digest and supplies configuration only.
            if ($environmentConfig.ContainsKey('build')) { throw "Environment '$environment' must not define a build step. Deployments consume the immutable release artifact." }
        }
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
    return Get-ComponentChannelVersion -Component $Component -Channel stable
}

function Get-ComponentChannelVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Component, [Parameter(Mandatory)][ValidateSet('stable','beta','rc')][string]$Channel)
    $prefix = [string]$Component.tagPrefix
    $versions = foreach ($tag in (Get-Git @('tag','--list',"$prefix/v*"))) {
        if ($tag -match "^$([regex]::Escape($prefix))/v(?<version>.+)$") {
            try {
                $version = ConvertFrom-SemVer $Matches.version
                if (($Channel -eq 'stable' -and -not $version.Channel) -or ($Channel -ne 'stable' -and $version.Channel -eq $Channel)) { $version }
            } catch { }
        }
    }
    if (-not $versions) { return $null }
    return $versions | Sort-Object Major,Minor,Patch -Descending | Select-Object -First 1
}

function Get-ChangedComponents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config, [string] $BaseRef = 'HEAD~1', [string] $Commit = 'HEAD')
    $paths = if ($BaseRef -eq 'HEAD~1') {
        $safeDirectory = (Get-Location).Path
        & git '-c' "safe.directory=$safeDirectory" rev-parse --verify --quiet "$Commit^" *> $null
        if ($LASTEXITCODE -eq 0) {
            Get-Git @('diff','--name-only',"$BaseRef...$Commit")
        } else {
            Get-Git @('diff-tree','--root','--no-commit-id','--name-only','-r',$Commit)
        }
    } else {
        Get-Git @('diff','--name-only',"$BaseRef...$Commit")
    }
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

        $artifact = @($sourceArtifacts | Where-Object {
            $_.component -eq $componentName -and $_.semanticVersion -eq $source.semanticVersion -and
            (($_.PSObject.Properties.Name -notcontains 'artifactType') -or $_.artifactType -eq 'zip')
        })
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
    [pscustomobject]@{ path = $zip; sha256 = $hash; component = $Release.component; semanticVersion = $Release.semanticVersion; artifactType = 'zip' }
}

function Expand-ReleaseEnvironmentValue {
    param([Parameter(Mandatory)][string]$Value)
    return [regex]::Replace($Value, '\$\{(?<name>[A-Za-z_][A-Za-z0-9_]*)\}', {
        param($match)
        $name = $match.Groups['name'].Value
        $resolved = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($resolved)) { throw "Environment variable '$name' is required to resolve '$Value'." }
        return $resolved
    })
}

function Invoke-ComponentContainerPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Release,
        [Parameter(Mandatory)][hashtable]$Component,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if (-not $Component.ContainsKey('publishing')) { return $null }
    $publishing = $Component.publishing
    if ($publishing -isnot [System.Collections.IDictionary] -or [string]$publishing.adapter -ne 'container') { return $null }
    if (-not $publishing.image) { throw "Container component '$($Release.component)' requires publishing.image." }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required to package container component '$($Release.component)'." }
    $image = Expand-ReleaseEnvironmentValue ([string]$publishing.image)
    $dockerfile = if ($publishing.dockerfile) { [string]$publishing.dockerfile } else { Join-Path ([string]$Component.path) 'Dockerfile' }
    $context = if ($publishing.context) { [string]$publishing.context } else { '.' }
    if (-not (Test-Path -LiteralPath $dockerfile -PathType Leaf)) { throw "Dockerfile not found for '$($Release.component)': $dockerfile" }
    if (-not (Test-Path -LiteralPath $context -PathType Container)) { throw "Docker context not found for '$($Release.component)': $context" }
    $tag = "${image}:$($Release.semanticVersion)"
    $version = ConvertFrom-SemVer ([string]$Release.semanticVersion)
    $versionPrefix = "$($version.Major).$($version.Minor).$($version.Patch)"
    $versionSuffix = if ($version.Channel) { "$($version.Channel).$($version.Sequence)" } else { '' }
    $assemblyVersion = "$versionPrefix.0"
    $dockerBuildArguments = @(
        'build', '--file', $dockerfile, '--tag', $tag,
        '--label', "org.opencontainers.image.version=$($Release.semanticVersion)",
        '--label', "org.opencontainers.image.revision=$($Release.commit)",
        '--build-arg', "DOTNET_Version=$($Release.semanticVersion)",
        '--build-arg', "DOTNET_VersionPrefix=$versionPrefix",
        '--build-arg', "DOTNET_VersionSuffix=$versionSuffix",
        '--build-arg', "DOTNET_AssemblyVersion=$assemblyVersion",
        '--build-arg', "DOTNET_FileVersion=$assemblyVersion",
        '--build-arg', "DOTNET_InformationalVersion=$($Release.semanticVersion)",
        $context
    )
    & docker @dockerBuildArguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed for '$($Release.component)'." }
    $componentOutput = Join-Path $OutputDirectory $Release.component
    New-Item -ItemType Directory -Force -Path $componentOutput | Out-Null
    $archive = Join-Path $componentOutput "$($Release.component)-v$($Release.semanticVersion).container.tar"
    & docker save '--output' $archive $tag 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Docker image export failed for '$($Release.component)'." }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    [pscustomobject]@{ path = $archive; sha256 = $hash; component = $Release.component; semanticVersion = $Release.semanticVersion; artifactType = 'container-image'; image = $image }
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
        if ($tagCommit -eq $Release.commit) {
            if ($Push) {
                $remoteCommit = Get-RemoteTagCommit -Tag $Release.tag
                if ($remoteCommit -and $remoteCommit -ne $Release.commit) { throw "Tag '$($Release.tag)' already exists on another commit remotely." }
                Get-Git @('push','--atomic','origin',"refs/tags/$($Release.tag)") | Out-Null
            }
            return [pscustomobject]@{ tag = $Release.tag; status = 'already-exists' }
        }
        throw "Tag '$($Release.tag)' already exists on another commit."
    }
    & git '-c' "safe.directory=$((Get-Location).Path)" tag -a $Release.tag $Release.commit -m "Release $($Release.component) $($Release.semanticVersion)"
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

function Test-CommitSha {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value -match '^[0-9a-f]{40}$'
}

function Assert-CandidateCommit {
    <#
        The candidate SHA is captured from the trigger context, never typed by a
        human. This is the boundary that proves the working tree actually is that
        commit before anything is built from it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExpectedSha, [string]$Commit = 'HEAD')
    $expected = $ExpectedSha.Trim().ToLowerInvariant()
    if (-not (Test-CommitSha $expected)) {
        throw "The candidate commit SHA could not be determined unambiguously: '$ExpectedSha' is not a full 40-character Git object name."
    }
    $head = (Get-Git @('rev-parse', $Commit) | Select-Object -First 1).Trim().ToLowerInvariant()
    if ($head -ne $expected) {
        throw "Checked-out HEAD '$head' does not equal the captured candidate SHA '$expected'. Refusing to build a release candidate from a different commit."
    }
    return $expected
}

function Get-ShortSha {
    param([Parameter(Mandatory)][string]$Sha)
    if (-not (Test-CommitSha $Sha.ToLowerInvariant())) { throw "Cannot shorten '$Sha': a full 40-character Git object name is required." }
    return $Sha.Substring(0, 12).ToLowerInvariant()
}

function Get-PushedImageDigest {
    <#
        The registry manifest digest - not a tag - is the authoritative artifact
        identity. It is resolved from the local daemon after the push, so the value
        recorded is the one the registry accepted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Image, [Parameter(Mandatory)][string]$Tag)
    $reference = "${Image}:$Tag"
    $output = & docker inspect '--format' '{{json .RepoDigests}}' $reference 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Unable to resolve the registry digest for '$reference': $($output -join ' ')" }
    $digests = @((($output | ForEach-Object { [string]$_ }) -join '') | ConvertFrom-Json)
    $matching = @($digests | Where-Object { ([string]$_).StartsWith("$Image@sha256:", [StringComparison]::OrdinalIgnoreCase) })
    if ($matching.Count -ne 1) { throw "Expected exactly one registry digest for '$reference' but found $($matching.Count). Push the image before resolving its digest." }
    $digest = (([string]$matching[0]) -split '@', 2)[1].ToLowerInvariant()
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Registry digest for '$reference' is not a SHA-256 manifest digest: $digest" }
    return $digest
}

function New-ReleaseManifest {
    <#
        The release manifest is the durable release identity. Every stage after the
        candidate build consumes this document instead of re-reading a mutable
        branch, a floating tag, or the current registry state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Provenance,
        [object]$RegistryPublication,
        [Parameter(Mandatory)][string]$CandidateSha,
        [string]$RunId = '',
        [string]$Repository = ''
    )
    $candidate = $CandidateSha.Trim().ToLowerInvariant()
    if (-not (Test-CommitSha $candidate)) { throw "Release manifest requires a full candidate commit SHA, got '$CandidateSha'." }
    $releases = @($Plan.releases)
    if ($releases.Count -eq 0) { throw 'Release manifest requires at least one release.' }
    if ([string]$Plan.commit -ne $candidate) { throw "Release plan commit '$($Plan.commit)' does not equal the candidate SHA '$candidate'." }

    $artifacts = @($Provenance.artifacts)
    $publications = if ($RegistryPublication) { @($RegistryPublication.publications) } else { @() }

    $components = foreach ($release in $releases) {
        $name = [string]$release.component
        if ([string]$release.commit -ne $candidate) { throw "Release for '$name' was built from '$($release.commit)', not from the candidate SHA '$candidate'." }
        $version = [string]$release.semanticVersion

        $archive = @($artifacts | Where-Object {
            $_.component -eq $name -and $_.semanticVersion -eq $version -and
            (($_.PSObject.Properties.Name -notcontains 'artifactType') -or $_.artifactType -eq 'zip')
        })
        if ($archive.Count -ne 1) { throw "Release manifest requires exactly one deployable archive for '$name' $version; found $($archive.Count)." }
        $archiveSha = ([string]$archive[0].sha256).ToLowerInvariant()
        if ($archiveSha -notmatch '^[0-9a-f]{64}$') { throw "Archive checksum for '$name' is not a SHA-256 value." }

        $containerArtifact = @($artifacts | Where-Object { $_.component -eq $name -and $_.semanticVersion -eq $version -and ($_.PSObject.Properties.Name -contains 'artifactType') -and $_.artifactType -eq 'container-image' })
        $image = $null; $imageDigest = $null; $imageSha256 = $null
        if ($containerArtifact.Count -gt 1) { throw "Release manifest requires at most one container image for '$name' $version." }
        if ($containerArtifact.Count -eq 1) {
            $image = [string]$containerArtifact[0].image
            $imageSha256 = ([string]$containerArtifact[0].sha256).ToLowerInvariant()
            $publication = @($publications | Where-Object { $_.component -eq $name -and $_.adapter -eq 'container' })
            if ($publication.Count -ne 1) { throw "Release manifest requires exactly one container publication record for '$name'; found $($publication.Count). Publish the image before writing the manifest." }
            $recorded = $publication[0]
            if ($recorded.PSObject.Properties.Name -notcontains 'imageDigest') { throw "Container publication for '$name' did not record a registry digest." }
            $imageDigest = ([string]$recorded.imageDigest).ToLowerInvariant()
            if ($imageDigest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Container publication for '$name' did not record a SHA-256 manifest digest." }
        }

        [pscustomobject]@{
            component = $name
            semanticVersion = $version
            channel = [string]$release.channel
            tag = [string]$release.tag
            archiveSha256 = $archiveSha
            image = $image
            imageDigest = $imageDigest
            imageArchiveSha256 = $imageSha256
        }
    }

    [pscustomobject]@{
        schema = 'release-manifest/v1'
        releaseId = "$([string]$Plan.channel)-$(Get-ShortSha $candidate)"
        candidateSha = $candidate
        channel = [string]$Plan.channel
        sourceBranch = [string]$Plan.branch
        repository = $Repository
        ciRunId = $RunId
        generatedAt = [DateTime]::UtcNow.ToString('o')
        components = @($components)
    }
}

function Assert-ReleaseIdentity {
    <#
        Digest equality between what QA approved and what another environment is
        about to receive. Anything that cannot be proven equal fails the release.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest, [Parameter(Mandatory)][object]$ApprovedManifest)
    if ([string]$Manifest.candidateSha -ne [string]$ApprovedManifest.candidateSha) {
        throw "Release identity mismatch: candidate SHA '$($Manifest.candidateSha)' does not equal the approved SHA '$($ApprovedManifest.candidateSha)'."
    }
    if ([string]$Manifest.releaseId -ne [string]$ApprovedManifest.releaseId) {
        throw "Release identity mismatch: release '$($Manifest.releaseId)' does not equal the approved release '$($ApprovedManifest.releaseId)'."
    }
    $approved = @{}
    foreach ($component in @($ApprovedManifest.components)) { $approved[[string]$component.component] = $component }
    $present = @(@($Manifest.components) | ForEach-Object { [string]$_.component })
    foreach ($name in $approved.Keys) {
        if ($present -notcontains $name) { throw "Release identity mismatch: approved component '$name' is missing from the deployment manifest." }
    }
    foreach ($component in @($Manifest.components)) {
        $name = [string]$component.component
        if (-not $approved.ContainsKey($name)) { throw "Release identity mismatch: component '$name' was not part of the approved release." }
        $expected = $approved[$name]
        if ([string]$component.semanticVersion -ne [string]$expected.semanticVersion) { throw "Release identity mismatch for '$name': version '$($component.semanticVersion)' does not equal approved '$($expected.semanticVersion)'." }
        if ([string]$component.archiveSha256 -ne [string]$expected.archiveSha256) { throw "Release identity mismatch for '$name': archive checksum does not equal the QA-approved checksum." }
        if ([string]$component.imageDigest -ne [string]$expected.imageDigest) { throw "Release identity mismatch for '$name': artifact digest '$($component.imageDigest)' does not equal the QA-approved digest '$($expected.imageDigest)'." }
    }
    return $true
}

function Invoke-DevelopmentComponentPackage {
    <#
        Development artifacts are deliberately not release artifacts: they are keyed
        by branch and SHA rather than by SemVer, and they never enter the promotion
        plan schema.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Release,
        [Parameter(Mandatory)][string]$VersionLabel,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $componentOutput = Join-Path $OutputDirectory $Release.component
    New-Item -ItemType Directory -Force -Path $componentOutput | Out-Null
    $zip = Join-Path $componentOutput "$($Release.component)-$VersionLabel.zip"
    $artifactPath = if ($Release.PSObject.Properties.Name -contains 'artifactPath') { [string]$Release.artifactPath } else { [string]$Release.path }
    $inputPath = Join-Path (Get-Location) $artifactPath
    if (-not (Test-Path -LiteralPath $inputPath)) { throw "Artifact path not found for '$($Release.component)': $inputPath" }
    Compress-Archive -Path $inputPath -DestinationPath $zip -Force
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    [pscustomobject]@{ path = $zip; sha256 = $hash; component = $Release.component; versionLabel = $VersionLabel; artifactType = 'zip' }
}

function Invoke-DevelopmentContainerBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Release,
        [Parameter(Mandatory)][hashtable]$Component,
        [Parameter(Mandatory)][string]$VersionLabel,
        [Parameter(Mandatory)][string]$CommitSha,
        [switch]$Push
    )
    if (-not $Component.ContainsKey('publishing')) { return $null }
    $publishing = $Component.publishing
    if ($publishing -isnot [System.Collections.IDictionary] -or [string]$publishing.adapter -ne 'container') { return $null }
    if (-not $publishing.image) { throw "Container component '$($Release.component)' requires publishing.image." }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required to build the development container for '$($Release.component)'." }
    $image = Expand-ReleaseEnvironmentValue ([string]$publishing.image)
    $dockerfile = if ($publishing.dockerfile) { [string]$publishing.dockerfile } else { Join-Path ([string]$Component.path) 'Dockerfile' }
    $context = if ($publishing.context) { [string]$publishing.context } else { '.' }
    if (-not (Test-Path -LiteralPath $dockerfile -PathType Leaf)) { throw "Dockerfile not found for '$($Release.component)': $dockerfile" }
    if (-not (Test-Path -LiteralPath $context -PathType Container)) { throw "Docker context not found for '$($Release.component)': $context" }
    $tag = "${image}:$VersionLabel"
    $arguments = @(
        'build', '--file', $dockerfile, '--tag', $tag,
        '--label', "org.opencontainers.image.version=0.0.0-$VersionLabel",
        '--label', "org.opencontainers.image.revision=$CommitSha",
        '--build-arg', "DOTNET_Version=0.0.0-$VersionLabel",
        '--build-arg', 'DOTNET_VersionPrefix=0.0.0',
        '--build-arg', "DOTNET_VersionSuffix=$VersionLabel",
        '--build-arg', 'DOTNET_AssemblyVersion=0.0.0.0',
        '--build-arg', 'DOTNET_FileVersion=0.0.0.0',
        '--build-arg', "DOTNET_InformationalVersion=0.0.0-$VersionLabel+$CommitSha",
        $context
    )
    & docker @arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed for '$($Release.component)'." }
    $digest = $null
    if ($Push) {
        & docker push $tag 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Docker push failed for '$($Release.component)'." }
        $digest = Get-PushedImageDigest -Image $image -Tag $VersionLabel
    }
    [pscustomobject]@{ component = $Release.component; image = $image; tag = $tag; versionLabel = $VersionLabel; digest = $digest; artifactType = 'container-image' }
}

. (Join-Path $PSScriptRoot 'ReleasePlanning.ps1')

Export-ModuleMember -Function Import-ReleaseConfig,Get-ComponentVersion,Get-ChangedComponents,New-ReleasePlan,New-ArtifactPromotionPlan,Invoke-ComponentPackage,Invoke-ComponentContainerPackage,Invoke-ComponentBuild,New-ReleaseTag,Assert-CandidateCommit,Get-ShortSha,Get-PushedImageDigest,New-ReleaseManifest,Assert-ReleaseIdentity,Resolve-ReleaseSource,Get-ReleaseBaseline,New-ManifestPromotionPlan,Invoke-DevelopmentComponentPackage,Invoke-DevelopmentContainerBuild
