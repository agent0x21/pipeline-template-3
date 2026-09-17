# Shared provider adapter. Never overwrite a release asset or move a Git tag.
function Invoke-ReleaseApi {
    param([string]$Path, [string]$Method = 'GET', [object]$Body, [switch]$AllowMissing)
    $headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $arguments = @{ Uri = "https://api.github.com/repos/$Repository/$Path"; Headers = $headers; Method = $Method }
    if ($null -ne $Body) { $arguments.Body = ($Body | ConvertTo-Json -Depth 30 -Compress); $arguments.ContentType = 'application/json' }
    try {
        # Invoke-RestMethod writes an array response as a single, non-enumerated pipeline
        # object. Without Write-Output, a caller piping into Where-Object/ForEach-Object
        # receives the whole array as one $_ instead of one item per asset.
        $response = Invoke-RestMethod @arguments
        Write-Output $response
    } catch {
        if ($AllowMissing -and $_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-StoredRelease {
    param([string]$Tag, [switch]$AllowMissing)
    Invoke-ReleaseApi -Path "releases/tags/$([uri]::EscapeDataString($Tag))" -AllowMissing:$AllowMissing
}

function Assert-StoredTagCommit {
    param([string]$Tag, [string]$ExpectedSha)
    $reference = Invoke-ReleaseApi "git/ref/tags/$([uri]::EscapeDataString($Tag))"
    $object = $reference.object
    for ($depth = 0; $object.type -eq 'tag' -and $depth -lt 5; $depth++) {
        $object = (Invoke-ReleaseApi "git/tags/$($object.sha)").object
    }
    if ($object.type -ne 'commit' -or $object.sha -ne $ExpectedSha) { throw "Tag '$Tag' does not identify the manifest source commit." }
}

function Get-StoredAsset {
    param([object]$Release, [string]$Name, [string]$Directory, [switch]$Optional)
    $assets = @(Invoke-ReleaseApi "releases/$($Release.id)/assets?per_page=100" | Where-Object { $_ -and $_.name -eq $Name })
    if ($assets.Count -eq 0 -and $Optional) { return $null }
    if ($assets.Count -ne 1) { throw "Release '$($Release.tag_name)' requires exactly one asset '$Name'." }
    if ($Name -ne [IO.Path]::GetFileName($Name)) { throw 'Invalid asset filename.' }
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $path = Join-Path $Directory $Name
    $headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/octet-stream'; 'X-GitHub-Api-Version' = '2022-11-28' }
    Invoke-WebRequest -Uri $assets[0].url -Headers $headers -OutFile $path
    if ($assets[0].PSObject.Properties.Name -contains 'digest' -and $assets[0].digest) {
        if ("sha256:$((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant())" -ne $assets[0].digest) { throw "Downloaded asset '$Name' failed its GitHub checksum." }
    }
    return $path
}

function Add-StoredAsset {
    param([object]$Release, [string]$Path, [string]$Name = '')
    if (-not $Name) { $Name = Split-Path -Leaf $Path }
    $existing = @(Invoke-ReleaseApi "releases/$($Release.id)/assets?per_page=100" | Where-Object { $_ -and $_.name -eq $Name })
    if ($existing.Count -gt 0) {
        $compare = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $download = Get-StoredAsset $Release $Name $compare
        if ((Get-FileHash $download).Hash -ne (Get-FileHash $Path).Hash) { throw "Immutable asset '$Name' already exists with different bytes." }
        return
    }
    $headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $uri = "https://uploads.github.com/repos/$Repository/releases/$($Release.id)/assets?name=$([uri]::EscapeDataString($Name))"
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/octet-stream' -InFile $Path | Out-Null
            return
        } catch {
            $statusCode = $null
            $requestId = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
                try {
                    $responseHeaders = $_.Exception.Response.Headers
                    if ($responseHeaders.Contains('X-GitHub-Request-Id')) { $requestId = ($responseHeaders.GetValues('X-GitHub-Request-Id') | Select-Object -First 1) }
                    elseif ($responseHeaders['X-GitHub-Request-Id']) { $requestId = $responseHeaders['X-GitHub-Request-Id'] }
                } catch {}
            }
            # GitHub's asset-storage backend intermittently rejects uploads with a generic
            # "Error saving asset" 5xx response that succeeds on retry; anything else (4xx,
            # or the final attempt) is treated as terminal.
            $transient = (-not $statusCode) -or $statusCode -ge 500
            if (-not $transient -or $attempt -eq $maxAttempts) {
                throw "Failed to upload release asset '$Name' to release '$($Release.tag_name)' (attempt $attempt/$maxAttempts, status=$statusCode, requestId=$requestId): $($_.Exception.Message)"
            }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1))
        }
    }
}

function ConvertTo-FencedJsonBlock {
    param([object]$Value)
    $fence = '```'
    $json = $Value | ConvertTo-Json -Depth 30
    @("${fence}json", $json, $fence) -join "`n"
}

function ConvertFrom-FencedJsonBlock {
    param([string]$Body)
    $fence = '```'
    $pattern = [regex]::Escape($fence) + 'json\r?\n(.*?)\r?\n' + [regex]::Escape($fence)
    $match = [regex]::Match($Body, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success) { return $match.Groups[1].Value | ConvertFrom-Json }
    return $Body | ConvertFrom-Json
}

function Save-ReleaseJson {
    param([object]$Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-EnvironmentReview {
    param([ValidateSet('QA','PROD')][string]$Environment, [string]$RunId = $env:GITHUB_RUN_ID)
    $reviews = @(Invoke-ReleaseApi "actions/runs/$RunId/approvals" | Where-Object {
        $_.state -eq 'approved' -and @($_.environments | Where-Object { $_ -and $_.name -eq $Environment }).Count -gt 0
    })
    if ($reviews.Count -eq 0) { throw "No GitHub reviewer evidence for $Environment. Configure required reviewers; bypass is not sign-off." }
    [pscustomobject]@{
        reviewers = @($reviews | ForEach-Object { $_.user.login } | Sort-Object -Unique)
        evidenceUrl = "https://api.github.com/repos/$Repository/actions/runs/$RunId/approvals"
        runId = $RunId
    }
}
