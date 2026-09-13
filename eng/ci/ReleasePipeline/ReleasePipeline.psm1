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
    if (-not $config.components -or @($config.components.Keys).Count -eq 0) { throw 'Configuration must define at least one component.' }
    if (-not $config.versioning) { throw 'Configuration must define versioning.' }
    if (-not $config.versioning.defaultBump) { $config.versioning.defaultBump = 'minor' }
    if ($config.versioning.defaultBump -notin @('major','minor','patch')) { throw 'versioning.defaultBump must be major, minor, or patch.' }
    foreach ($name in $config.components.Keys) {
        $component = $config.components[$name]
        foreach ($required in @('path','tagPrefix')) { if (-not $component[$required]) { throw "Component '$name' requires '$required'." } }
    }
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
        $versionText = if ($ExactVersions[$name]) { [string]$ExactVersions[$name] } else {
            $base = if ($current) { $current } else { ConvertFrom-SemVer ([string]$(if ($component.ContainsKey('initialVersion')) { $component.initialVersion } else { '0.0.0' })) }
            $major = $base.Major; $minor = $base.Minor; $patch = $base.Patch
            if ($bump.Type -eq 'major') { $major++; $minor = 0; $patch = 0 } elseif ($bump.Type -eq 'minor') { $minor++; $patch = 0 } else { $patch++ }
            ConvertTo-SemVer $major $minor $patch '' 0
        }
        $parsed = ConvertFrom-SemVer $versionText
        if ($current -and (Compare-CoreVersion $parsed $current) -le 0 -and -not $ExactVersions[$name]) { throw "Calculated version for '$name' is not newer than current version." }
        if ($ExactVersions[$name] -and $current -and (Compare-CoreVersion $parsed $current) -le 0) { throw "Exact version for '$name' must be greater than current stable version." }
        $sequence = 0
        if ($channel -ne 'stable' -and -not ($ExactVersions[$name] -and $parsed.Channel)) {
            $tagPrefix = [string]$component.tagPrefix
            $tagPattern = "$tagPrefix/v$versionText-$channel.*"
            $sequence = @(Get-Git @('tag','--list',$tagPattern) | ForEach-Object { if ($_ -match "-$channel\.(?<n>\d+)$") { [int]$Matches.n } } | Measure-Object -Maximum).Maximum
            if (-not $sequence) { $sequence = 0 }; $sequence++
            $versionText = "$versionText-$channel.$sequence"
        }
        if ($ExactVersions[$name] -and $parsed.Channel -and $parsed.Channel -ne $channel) { throw "Exact version channel for '$name' does not match branch channel '$channel'." }
        [pscustomobject]@{ component = $name; path = [string]$component.path; componentType = if ($component.ContainsKey('type')) { [string]$component.type } else { '' }; artifactPath = if ($component.ContainsKey('package') -and $component.package.ContainsKey('path')) { [string]$component.package.path } else { [string]$component.path }; semanticVersion = $versionText; tag = "$($component.tagPrefix)/v$versionText"; channel = $channel; bump = $bump.Type; bumpSource = if ($ExactVersions[$name]) { 'exact-version' } else { $bump.Source }; currentVersion = if ($current) { $current.Text } else { $null }; commit = $commitSha; ciRunId = $CiRunId; repository = $Repository; buildCommand = if ($component.ContainsKey('build') -and $component.build.ContainsKey('command')) { [string]$component.build.command } else { '' }; buildSolution = if ($component.ContainsKey('build') -and $component.build.ContainsKey('solution')) { [string]$component.build.solution } else { '' }; buildMsbuildPath = if ($component.ContainsKey('build') -and $component.build.ContainsKey('msbuildPath')) { [string]$component.build.msbuildPath } else { '' }; buildConfiguration = if ($component.ContainsKey('build') -and $component.build.ContainsKey('configuration')) { [string]$component.build.configuration } else { 'Release' }; testCommand = if ($component.ContainsKey('test') -and $component.test.ContainsKey('command')) { [string]$component.test.command } else { '' } }
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
    param([string]$PreferredPath)
    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath -PathType Leaf)) { return (Resolve-Path -LiteralPath $PreferredPath).Path }
    $command = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $vswhere = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($vswhere) {
        $candidate = & $vswhere.Source '-latest' '-products' '*' '-requires' 'Microsoft.Component.MSBuild' '-find' 'MSBuild\\**\\Bin\\MSBuild.exe' 2>$null | Select-Object -First 1
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'MSBuild.exe was not found. Install Visual Studio Build Tools or provide build.msbuildPath.'
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

function New-ReleaseTag {
    [CmdletBinding()] param([Parameter(Mandatory)][pscustomobject]$Release, [switch]$Push)
    $existing = @(Get-Git @('tag','--list',$Release.tag))
    if ($existing) {
        $tagCommit = Get-Git @('rev-list','-n','1',$Release.tag) | Select-Object -First 1
        if ($tagCommit -eq $Release.commit) { return [pscustomobject]@{ tag = $Release.tag; status = 'already-exists' } }
        throw "Tag '$($Release.tag)' already exists on another commit."
    }
    & git tag -a $Release.tag $Release.commit -m "Release $($Release.component) $($Release.semanticVersion)"
    if ($LASTEXITCODE -ne 0) { throw "Unable to create tag '$($Release.tag)'." }
    if ($Push) { Get-Git @('push','--atomic','origin',$Release.tag) | Out-Null }
    [pscustomobject]@{ tag = $Release.tag; status = 'created' }
}

Export-ModuleMember -Function Import-ReleaseConfig,Get-ReleaseChannel,Get-ComponentVersion,New-ReleasePlan,Invoke-ComponentPackage,Invoke-ComponentBuild,New-ReleaseTag
