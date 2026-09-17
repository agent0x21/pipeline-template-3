[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ProvenancePath,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Token = $env:GITHUB_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Repository)) { throw 'Repository is required. Set GITHUB_REPOSITORY or pass -Repository.' }
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'Token is required. Set GITHUB_TOKEN or pass -Token.' }

function Resolve-DownloadedArtifactPath {
    param([Parameter(Mandatory)][string]$RecordedPath, [Parameter(Mandatory)][string]$SourceProvenancePath)
    if (Test-Path -LiteralPath $RecordedPath -PathType Leaf) { return (Resolve-Path -LiteralPath $RecordedPath).Path }
    $name = Split-Path -Leaf $RecordedPath
    $matches = @(Get-ChildItem -LiteralPath (Split-Path -Parent $SourceProvenancePath) -Recurse -File -Filter $name -ErrorAction SilentlyContinue)
    if ($matches.Count -ne 1) { throw "Could not resolve the immutable artifact '$RecordedPath' beside '$SourceProvenancePath'." }
    return $matches[0].FullName
}

function Test-GitHubReleaseAssetPresent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$TagName,
        [AllowNull()][object[]]$Assets
    )
    $existing = @($Assets | Where-Object { $_ -and $_.name -eq $Name })
    if ($existing.Count -gt 1) { throw "GitHub release '$TagName' contains multiple assets named '$Name'." }
    if ($existing.Count -eq 0) { return $false }
    if ([string]$existing[0].digest -ne "sha256:$Sha256") { throw "GitHub release asset '$Name' already exists for '$TagName' with a different or unavailable SHA-256 digest." }
    return $true
}

function Get-GitHubApiErrorDetail {
    param([Parameter(Mandatory)]$ErrorRecord)
    $statusCode = $null
    $retryAfterSeconds = $null
    $body = $null
    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response' -and $ErrorRecord.Exception.Response) {
        $response = $ErrorRecord.Exception.Response
    }
    if ($response) {
        try { $statusCode = [int]$response.StatusCode } catch {}
        if ($response.PSObject.Properties.Name -contains 'Headers' -and $response.Headers) {
            try {
                $retryAfter = $response.Headers.RetryAfter
                if ($retryAfter -and $retryAfter.Delta) { $retryAfterSeconds = [math]::Ceiling($retryAfter.Delta.Value.TotalSeconds) }
                elseif ($retryAfter -and $retryAfter.Date) { $retryAfterSeconds = [math]::Max(0, [math]::Ceiling(($retryAfter.Date.Value - [DateTimeOffset]::UtcNow).TotalSeconds)) }
            } catch {}
            if (-not $retryAfterSeconds) {
                try {
                    $rawValues = $null
                    if ($response.Headers.TryGetValues('Retry-After', [ref]$rawValues) -and $rawValues) {
                        $raw = @($rawValues)[0]
                        if ($raw -match '^\d+$') { $retryAfterSeconds = [int]$raw }
                        else {
                            $parsedDate = [DateTimeOffset]::MinValue
                            if ([DateTimeOffset]::TryParse($raw, [ref]$parsedDate)) { $retryAfterSeconds = [math]::Max(0, [math]::Ceiling(($parsedDate - [DateTimeOffset]::UtcNow).TotalSeconds)) }
                        }
                    }
                } catch {}
            }
        }
    }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = $ErrorRecord.ErrorDetails.Message }
    if (-not $body -and $response -and $response.PSObject.Properties.Name -contains 'Content' -and $response.Content) {
        try { $body = $response.Content.ReadAsStringAsync().Result } catch {}
    }
    if (-not $body) { $body = $ErrorRecord.Exception.Message }
    [pscustomobject]@{ StatusCode = $statusCode; Body = $body; RetryAfterSeconds = $retryAfterSeconds }
}

function Test-GitHubApiErrorRetryable {
    param([AllowNull()][Nullable[int]]$StatusCode)
    # No status code at all means the request never got a response (timeout, DNS
    # failure, dropped connection): transient by nature. 408/429/5xx are GitHub's
    # documented retryable signals; everything else (401/403/404/409/422/...) is a
    # permanent auth/validation problem that a retry cannot fix.
    if (-not $StatusCode) { return $true }
    if ($StatusCode -eq 408 -or $StatusCode -eq 429) { return $true }
    if ($StatusCode -ge 500) { return $true }
    return $false
}

function Get-GitHubApiRetryDelaySeconds {
    param([Parameter(Mandatory)][int]$Attempt, [AllowNull()][Nullable[int]]$RetryAfterSeconds)
    if ($RetryAfterSeconds -and $RetryAfterSeconds -gt 0) { return $RetryAfterSeconds }
    return [math]::Pow(2, $Attempt - 1)
}

function Publish-GitHubReleaseAsset {
    param(
        [Parameter(Mandatory)]$GitHubRelease,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ContentType,
        [int]$MaxAttempts = 5
    )
    $tagName = [string]$GitHubRelease.tag_name
    if (Test-GitHubReleaseAssetPresent -Name $Name -Sha256 $Sha256 -TagName $tagName -Assets $GitHubRelease.assets) {
        Write-Host "GitHub release asset already exists for ${tagName}: $Name"
        return
    }

    $uploadUri = "https://uploads.github.com/repos/$Repository/releases/$($GitHubRelease.id)/assets?name=$([uri]::EscapeDataString($Name))&label=$([uri]::EscapeDataString($Label))"
    $assetsUri = "https://api.github.com/repos/$Repository/releases/$($GitHubRelease.id)/assets?per_page=100"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "Uploading GitHub release asset for ${tagName}: $Name (attempt $attempt of $MaxAttempts)"
        try {
            Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $Headers -ContentType $ContentType -InFile $Path | Out-Null
            Write-Host "Uploaded GitHub release asset for ${tagName}: $Name"
            return
        } catch {
            $detail = Get-GitHubApiErrorDetail -ErrorRecord $_

            # The upload may have succeeded server-side even though the client observed
            # a failure (dropped connection, timeout, proxy error). Re-check the live
            # asset list before retrying so a retry never tries to recreate an asset
            # GitHub already stored.
            $liveAssets = $null
            try { $liveAssets = @(Invoke-RestMethod -Method Get -Uri $assetsUri -Headers $Headers) } catch {}
            if ($liveAssets -and (Test-GitHubReleaseAssetPresent -Name $Name -Sha256 $Sha256 -TagName $tagName -Assets $liveAssets)) {
                Write-Host "GitHub release asset for ${tagName} was already stored despite an upload error on attempt $attempt of ${MaxAttempts}: $Name"
                return
            }

            $isLastAttempt = $attempt -eq $MaxAttempts
            $retryable = Test-GitHubApiErrorRetryable -StatusCode $detail.StatusCode
            if (-not $retryable -or $isLastAttempt) {
                throw "Failed to upload GitHub release asset '$Name' for release '$tagName' (attempt $attempt of $MaxAttempts, status=$($detail.StatusCode)): $($detail.Body)"
            }

            $delaySeconds = Get-GitHubApiRetryDelaySeconds -Attempt $attempt -RetryAfterSeconds $detail.RetryAfterSeconds
            Write-Warning "Transient failure uploading GitHub release asset '$Name' for '$tagName' (attempt $attempt of $MaxAttempts, status=$($detail.StatusCode)): $($detail.Body). Retrying in $delaySeconds second(s)."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$provenance = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
$planProperties = $plan.PSObject.Properties.Name
# Release plans use 'releases'; promotion plans (beta -> rc, rc -> stable) use
# 'promotions'. Check property existence before accessing either name: under
# Set-StrictMode, reading a missing property throws instead of returning $null.
if ($planProperties -contains 'releases') { $releases = @($plan.releases) }
elseif ($planProperties -contains 'promotions') { $releases = @($plan.promotions) }
else { throw "Unrecognized plan schema at '$PlanPath': expected a 'releases' or 'promotions' property." }
if ($releases.Count -eq 0) { Write-Host 'The release plan is empty; no GitHub release assets will be uploaded.'; return }

$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "Bearer $Token"; 'X-GitHub-Api-Version' = '2022-11-28' }
$releaseBaseUri = "https://api.github.com/repos/$Repository/releases"
foreach ($release in $releases) {
    $sourceVersion = if ($release.PSObject.Properties.Name -contains 'sourceSemanticVersion') { [string]$release.sourceSemanticVersion } else { [string]$release.semanticVersion }
    $artifacts = @($provenance.artifacts | Where-Object { $_.component -eq $release.component -and $_.semanticVersion -eq $sourceVersion })
    if ($artifacts.Count -eq 0) { throw "Provenance does not contain artifacts for '$($release.component)' version '$sourceVersion'." }

    $tagUri = [uri]::EscapeDataString([string]$release.tag)
    try {
        $githubRelease = Invoke-RestMethod -Method Get -Uri "$releaseBaseUri/tags/$tagUri" -Headers $headers
    } catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 404) { throw "GitHub release metadata for '$($release.tag)' does not exist. Publish metadata before uploading assets." }
        throw
    }

    $releaseArtifacts = foreach ($artifact in $artifacts) {
        $expectedHash = ([string]$artifact.sha256).ToLowerInvariant()
        if ($expectedHash -notmatch '^[a-f0-9]{64}$') { throw "Artifact digest for '$($release.component)' is not a SHA-256 value." }
        $artifactPath = Resolve-DownloadedArtifactPath -RecordedPath ([string]$artifact.path) -SourceProvenancePath $ProvenancePath
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw "Artifact digest mismatch for '$artifactPath'. Expected $expectedHash, got $actualHash." }
        $artifactType = if ($artifact.PSObject.Properties.Name -contains 'artifactType') { [string]$artifact.artifactType } else { 'zip' }
        $suffix = if ($artifactType -eq 'container-image') { '.container.tar' } elseif ($artifactType -eq 'zip') { '.zip' } else { throw "Unsupported GitHub release artifact type '$artifactType'." }
        $assetName = "$($release.component)-v$($release.semanticVersion)$suffix"
        Publish-GitHubReleaseAsset -GitHubRelease $githubRelease -Name $assetName -Path $artifactPath -Sha256 $expectedHash -Headers $headers -Repository $Repository -Label "$($release.component) $artifactType" -ContentType 'application/octet-stream'
        [pscustomobject]@{ path = $assetName; sha256 = $expectedHash; component = $release.component; semanticVersion = $release.semanticVersion; artifactType = $artifactType }
    }
    $releaseProvenance = [pscustomobject]@{ plan = [pscustomobject]@{ releases = @($release) }; artifacts = @($releaseArtifacts) }
    $provenanceAsset = "$($release.component)-v$($release.semanticVersion).provenance.json"
    $releaseProvenancePath = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString('N')).json"
    try {
        $releaseProvenance | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $releaseProvenancePath -Encoding utf8
        $provenanceHash = (Get-FileHash -LiteralPath $releaseProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Publish-GitHubReleaseAsset -GitHubRelease $githubRelease -Name $provenanceAsset -Path $releaseProvenancePath -Sha256 $provenanceHash -Headers $headers -Repository $Repository -Label "$($release.component) release provenance" -ContentType 'application/json'
    } finally {
        Remove-Item -LiteralPath $releaseProvenancePath -Force -ErrorAction SilentlyContinue
    }
}
