[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Token = $env:GITHUB_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Repository)) { throw 'Repository is required. Set GITHUB_REPOSITORY or pass -Repository.' }
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'Token is required. Set GITHUB_TOKEN or pass -Token.' }

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$planProperties = $plan.PSObject.Properties.Name
# Release plans use 'releases'; promotion plans (beta -> rc, rc -> stable) use
# 'promotions'. Check property existence before accessing either name: under
# Set-StrictMode, reading a missing property throws instead of returning $null.
if ($planProperties -contains 'releases') { $releases = @($plan.releases) }
elseif ($planProperties -contains 'promotions') { $releases = @($plan.promotions) }
else { throw "Unrecognized plan schema at '$PlanPath': expected a 'releases' or 'promotions' property." }
if ($releases.Count -eq 0) {
    Write-Host 'The release plan is empty; no GitHub release metadata will be published.'
    return
}

$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "Bearer $Token"; 'X-GitHub-Api-Version' = '2022-11-28' }
$baseUri = "https://api.github.com/repos/$Repository/releases"
foreach ($release in $releases) {
    $tag = [string]$release.tag
    $tagUri = [uri]::EscapeDataString($tag)
    try {
        Invoke-RestMethod -Method Get -Uri "$baseUri/tags/$tagUri" -Headers $headers | Out-Null
        Write-Host "GitHub release metadata already exists for $tag."
        continue
    } catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -ne 404) { throw }
    }

    $body = @{
        tag_name = $tag
        target_commitish = [string]$release.commit
        name = "$($release.component) v$($release.semanticVersion)"
        prerelease = ([string]$release.channel -ne 'stable')
        generate_release_notes = $true
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri $baseUri -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
    Write-Host "Published GitHub release metadata for $tag."
}
