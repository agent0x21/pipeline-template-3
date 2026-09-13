[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [Parameter(Mandatory)][ValidateSet('rc','stable')][string]$TargetChannel,
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$Commit = 'HEAD',
    [string]$OutputPath = 'promotion-sources.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

function Invoke-SourceGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $safeDirectory = (Get-Location).Path
    $output = & git '-c' "safe.directory=$safeDirectory" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
    return @($output | ForEach-Object { [string]$_ })
}

$config = Import-ReleaseConfig $ConfigPath
$sourceChannel = if ($TargetChannel -eq 'rc') { 'beta' } else { 'rc' }
$commitSha = Invoke-SourceGit @('rev-parse',$Commit) | Select-Object -First 1
$baseSha = if ($BaseRef -match '^0+$') { $null } else { Invoke-SourceGit @('rev-parse',$BaseRef) | Select-Object -First 1 }
if (-not $baseSha) {
    $result = [pscustomobject]@{ targetChannel = $TargetChannel; sourceChannel = $sourceChannel; commit = $commitSha; sources = @() }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    $result | ConvertTo-Json -Depth 8
    return
}

$changed = @(Get-ChangedComponents -Config $config -BaseRef $baseSha -Commit $commitSha)
$rangeCommits = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($rangeCommit in (Invoke-SourceGit @('rev-list',"$baseSha..$commitSha"))) { [void]$rangeCommits.Add($rangeCommit) }

$sources = foreach ($componentName in $changed) {
    $component = $config.components[$componentName]
    $prefix = [string]$component.tagPrefix
    $candidates = foreach ($tag in (Invoke-SourceGit @('tag','--list',"$prefix/v*-$sourceChannel.*"))) {
        if ($tag -notmatch "^$([regex]::Escape($prefix))/v.+-$sourceChannel\.\d+$") { continue }
        $tagCommit = Invoke-SourceGit @('rev-list','-n','1',$tag) | Select-Object -First 1
        if ($rangeCommits.Contains($tagCommit)) { [pscustomobject]@{ component = $componentName; tag = $tag; commit = $tagCommit } }
    }
    if (@($candidates).Count -eq 0) {
        throw "No $sourceChannel release tag for component '$componentName' was introduced by this branch promotion. Create a $sourceChannel release on the source branch first."
    }
    if (@($candidates).Count -gt 1) {
        throw "Multiple $sourceChannel release tags for component '$componentName' were introduced by this branch promotion: $((@($candidates).tag -join ', ')). Promote one candidate at a time."
    }
    $candidate = @($candidates)[0]
    & git '-c' "safe.directory=$((Get-Location).Path)" diff --quiet $candidate.commit $commitSha -- ([string]$component.path)
    if ($LASTEXITCODE -ne 0) {
        throw "The promoted branch changes '$componentName' after $($candidate.tag). Build a new $sourceChannel artifact from the promoted source before continuing."
    }
    $candidate
}

$result = [pscustomobject]@{ targetChannel = $TargetChannel; sourceChannel = $sourceChannel; commit = $commitSha; sources = @($sources) }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$result | ConvertTo-Json -Depth 8
