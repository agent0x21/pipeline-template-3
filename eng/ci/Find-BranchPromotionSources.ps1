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
        if ($tag -notmatch "^$([regex]::Escape($prefix))/v(?<core>\d+\.\d+\.\d+)-$sourceChannel\.(?<sequence>\d+)$") { continue }
        $tagCommit = Invoke-SourceGit @('rev-list','-n','1',$tag) | Select-Object -First 1
        if ($rangeCommits.Contains($tagCommit)) {
            [pscustomobject]@{ component = $componentName; tag = $tag; commit = $tagCommit; core = $Matches.core; sequence = [int]$Matches.sequence }
        }
    }
    if (@($candidates).Count -eq 0) {
        throw "No $sourceChannel release tag for component '$componentName' was introduced by this branch promotion. Create a $sourceChannel release on the source branch first."
    }
    $distinctCores = @(@($candidates).core | Sort-Object -Unique)
    if ($distinctCores.Count -gt 1) {
        throw "Multiple conflicting $sourceChannel release base versions for component '$componentName' were introduced by this branch promotion: $((@($candidates).tag -join ', ')). Promote one candidate at a time."
    }
    # Sequential beta/RC iterations of the same base version (for example beta.1 then
    # beta.2) can legitimately land in one pushed range. That is not a conflict: the
    # highest sequence number is the intended candidate, and the diff check below still
    # rejects it if branch content moved on past that tag.
    $candidate = @($candidates) | Sort-Object sequence -Descending | Select-Object -First 1
    # A release tag must name an actual ancestor of the promoted branch tip.  This is
    # normally implied by the pushed range above, but retain the explicit assertion as
    # the traceability boundary: squash and rebase merges recreate commits and must
    # never be treated as a promotion of the artifact built from the original commit.
    & git '-c' "safe.directory=$((Get-Location).Path)" merge-base --is-ancestor $candidate.commit $commitSha
    if ($LASTEXITCODE -ne 0) {
        throw "The source commit for $($candidate.tag) is not contained by the promoted branch tip. Merge the approved source without squashing or rebasing it."
    }
    & git '-c' "safe.directory=$((Get-Location).Path)" diff --quiet $candidate.commit $commitSha -- ([string]$component.path)
    if ($LASTEXITCODE -ne 0) {
        throw "The promoted branch changes '$componentName' after $($candidate.tag). Build a new $sourceChannel artifact from the promoted source before continuing."
    }
    $candidate
}

$result = [pscustomobject]@{ targetChannel = $TargetChannel; sourceChannel = $sourceChannel; commit = $commitSha; sources = @($sources) }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$result | ConvertTo-Json -Depth 8
