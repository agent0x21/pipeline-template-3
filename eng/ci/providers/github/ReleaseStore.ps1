# Shared provider adapter. Never overwrite a release asset or move a Git tag.
function Invoke-ReleaseApi {
    param([string]$Path, [string]$Method = 'GET', [object]$Body, [switch]$AllowMissing)
    $headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $arguments = @{ Uri = "https://api.github.com/repos/$Repository/$Path"; Headers = $headers; Method = $Method }
    if ($null -ne $Body) { $arguments.Body = ($Body | ConvertTo-Json -Depth 30 -Compress); $arguments.ContentType = 'application/json' }
    try { Invoke-RestMethod @arguments } catch {
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
    Invoke-RestMethod -Method Post -Uri "https://uploads.github.com/repos/$Repository/releases/$($Release.id)/assets?name=$([uri]::EscapeDataString($Name))" -Headers $headers -ContentType 'application/octet-stream' -InFile $Path | Out-Null
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
