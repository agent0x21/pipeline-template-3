<#
    Deploys an already-published release artifact to one environment.

    This script never builds, packages, compiles, or republishes the application.
    It resolves the immutable artifact digest recorded in the release manifest,
    proves the registry still serves that exact digest, and hands the digest to an
    optional environment deployment command. Environment-specific configuration,
    secrets, and endpoints are supplied externally at deployment time; the artifact
    itself is environment independent.

    For production, -ApprovedManifestPath is mandatory: the digest being deployed
    must equal the digest QA approved or the release fails.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Environment,
    [string]$ApprovedManifestPath = '',
    [switch]$RequireApprovedRelease,
    [switch]$PublishAlias,
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$config = Import-ReleaseConfig $ConfigPath
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.schema -ne 'release-manifest/v1') { throw "'$ManifestPath' is not a release manifest. Deployments must consume the persisted release identity." }

if ($RequireApprovedRelease -and -not $ApprovedManifestPath) {
    throw "Environment '$Environment' requires the QA-approved release manifest. Deployment cannot proceed without proof that this artifact is the approved artifact."
}
if ($ApprovedManifestPath) {
    $approved = Get-Content -LiteralPath $ApprovedManifestPath -Raw | ConvertFrom-Json
    if ([string]$approved.schema -ne 'release-manifest/v1') { throw "'$ApprovedManifestPath' is not a release manifest." }
    Assert-ReleaseIdentity -Manifest $manifest -ApprovedManifest $approved | Out-Null
    Write-Host "Verified deployment identity against the QA-approved release '$($approved.releaseId)' at $($approved.candidateSha)."
}

$environmentConfig = if ($config.ContainsKey('environments') -and $config.environments -and $config.environments.ContainsKey($Environment)) { $config.environments[$Environment] } else { @{} }
$aliasTag = if ($environmentConfig.ContainsKey('aliasTag')) { [string]$environmentConfig.aliasTag } else { '' }
$deployCommand = if ($environmentConfig.ContainsKey('deploy') -and $environmentConfig.deploy -is [System.Collections.IDictionary] -and $environmentConfig.deploy.ContainsKey('command')) { [string]$environmentConfig.deploy.command } else { '' }

$deployments = foreach ($component in @($manifest.components)) {
    $name = [string]$component.component
    $digest = [string]$component.imageDigest
    if (-not $digest) {
        Write-Host "Component '$name' has no container artifact; nothing to deploy to '$Environment'."
        continue
    }
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Component '$name' does not carry a SHA-256 artifact digest; it cannot be traced to the candidate commit." }
    $reference = "$([string]$component.image)@$digest"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required to resolve the immutable artifact for '$name'." }
    & docker pull $reference 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "The registry does not serve '$reference'. The artifact cannot be traced to the approved release." }

    if ($PublishAlias -and $aliasTag) {
        # Convenience alias only. The digest above stays authoritative.
        $alias = "$([string]$component.image):$aliasTag"
        & docker tag $reference $alias 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Unable to tag the convenience alias '$alias'." }
        & docker push $alias 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Unable to push the convenience alias '$alias'." }
    }

    if ($deployCommand) {
        $environmentVariables = @{
            RELEASE_ENVIRONMENT = $Environment
            RELEASE_ID = [string]$manifest.releaseId
            RELEASE_GIT_SHA = [string]$manifest.candidateSha
            RELEASE_COMPONENT = $name
            RELEASE_VERSION = [string]$component.semanticVersion
            RELEASE_IMAGE = [string]$component.image
            RELEASE_IMAGE_DIGEST = $digest
            RELEASE_IMAGE_REFERENCE = $reference
        }
        foreach ($key in $environmentVariables.Keys) { Set-Item -Path "env:$key" -Value $environmentVariables[$key] }
        & pwsh -NoProfile -NonInteractive -Command $deployCommand 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Deployment command failed for '$name' in '$Environment'." }
    }

    [pscustomobject]@{
        component = $name
        semanticVersion = [string]$component.semanticVersion
        image = [string]$component.image
        imageDigest = $digest
        imageReference = $reference
        aliasTag = if ($PublishAlias -and $aliasTag) { $aliasTag } else { $null }
        deployCommandInvoked = [bool]$deployCommand
    }
}

$record = [pscustomobject]@{
    schema = 'environment-deployment/v1'
    environment = $Environment
    releaseId = [string]$manifest.releaseId
    candidateSha = [string]$manifest.candidateSha
    approvedManifest = if ($ApprovedManifestPath) { (Resolve-Path -LiteralPath $ApprovedManifestPath).Path } else { $null }
    rebuilt = $false
    deployedAt = [DateTime]::UtcNow.ToString('o')
    components = @($deployments)
}
if (-not $OutputPath) { $OutputPath = "deployment-$Environment.json" }
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$record | ConvertTo-Json -Depth 12
