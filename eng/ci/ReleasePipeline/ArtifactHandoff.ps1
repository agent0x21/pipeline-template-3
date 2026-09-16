function Assert-ReleaseManifestV2 {
    param([Parameter(Mandatory)][object]$Manifest, [string]$Repository = '')
    if ($Manifest.schema -ne 'release-manifest/v2') { throw 'A release-manifest/v2 identity is required. Legacy releases require manual recovery.' }
    if ($Manifest.releaseId -notmatch '^release/[A-Za-z0-9._-]+$' -or $Manifest.candidateSha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid release identity.' }
    if ($Repository -and $Manifest.repository -ne $Repository) { throw 'Release belongs to another repository.' }
    if (@($Manifest.components).Count -eq 0) { throw 'Empty release manifest.' }
    $seen = @{}
    foreach ($component in $Manifest.components) {
        if ($component.component -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid component name.' }
        if ($seen.ContainsKey($component.component)) { throw 'Duplicate release component.' }
        $seen[$component.component] = $true
        if ($component.semanticVersion -notmatch '^\d+\.\d+\.\d+-rc\.\d+$') { throw 'Release component must identify an RC.' }
        if (-not ([string]$component.tag).EndsWith("/v$($component.semanticVersion)", [StringComparison]::Ordinal)) { throw 'Component tag does not match its RC version.' }
        if ($component.archiveSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid ZIP checksum.' }
        if ($component.archiveAsset -notmatch '^[A-Za-z0-9._-]+\.zip$') { throw 'Invalid ZIP asset name.' }
        if ($component.archiveAsset -ne "$($component.component)-v$($component.semanticVersion).zip") { throw 'ZIP asset name does not match its component version.' }
        if ($component.imageDigest -and ($component.imageDigest -notmatch '^sha256:[a-f0-9]{64}$' -or -not $component.image)) { throw 'Invalid container identity.' }
    }
}

function Test-HandoffArtifacts {
    param([Parameter(Mandatory)][object]$Manifest, [Parameter(Mandatory)][string]$Directory, [switch]$VerifyContainers)
    Assert-ReleaseManifestV2 $Manifest
    foreach ($component in $Manifest.components) {
        $path = Join-Path $Directory $component.archiveAsset
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing artifact '$($component.archiveAsset)'." }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $component.archiveSha256) { throw "ZIP checksum mismatch for '$($component.component)'." }
        if ($VerifyContainers -and $component.imageDigest) {
            & docker manifest inspect "$($component.image)@$($component.imageDigest)" *> $null
            if ($LASTEXITCODE -ne 0) { throw "Container digest unavailable for '$($component.component)'." }
        }
    }
}

function Assert-QaSignoff {
    param([object]$Manifest, [string]$ManifestSha256, [object]$Approval)
    Assert-ReleaseManifestV2 $Manifest
    if ($Approval.schema -ne 'qa-signoff/v2' -or $Approval.environment -ne 'QA' -or $Approval.status -ne 'QA-approved') { throw 'QA sign-off is required.' }
    if ($Approval.releaseId -ne $Manifest.releaseId -or $Approval.candidateSha -ne $Manifest.candidateSha -or $Approval.manifestSha256 -ne $ManifestSha256) { throw 'QA approval does not match this release manifest.' }
    if (@($Approval.reviewers).Count -eq 0 -or -not $Approval.evidenceUrl) { throw 'QA approval has no reviewer evidence.' }
}

function New-ArtifactHandoff {
    param([object]$Manifest, [string]$ManifestSha256, [ValidateSet('QA','PROD')][string]$Environment, [string]$Directory)
    Assert-ReleaseManifestV2 $Manifest
    [pscustomobject]@{
        schema = 'artifact-handoff/v2'; status = 'prepared'; environment = $Environment
        releaseId = $Manifest.releaseId; candidateSha = $Manifest.candidateSha; manifestSha256 = $ManifestSha256
        preparedAt = [DateTime]::UtcNow.ToString('o'); installed = $false
        components = @($Manifest.components | ForEach-Object {
            [pscustomobject]@{
                component = $_.component; version = $_.semanticVersion; archiveSha256 = $_.archiveSha256
                localPath = Join-Path $Directory $_.archiveAsset
                downloadUrl = "https://github.com/$($Manifest.repository)/releases/download/$($Manifest.releaseId)/$($_.archiveAsset)"
                imageReference = if ($_.imageDigest) { "$($_.image)@$($_.imageDigest)" } else { $null }
            }
        })
    }
}
