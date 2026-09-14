<#
    Records the QA approval against the persisted release identity.

    Approval is never "whatever is currently on the qa branch": it names the exact
    Git SHA, the release identifier, and the artifact digest that QA actually ran.
    The QA deployment record must prove the deployed digest equals the released
    digest before an approval record can be written.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$QaDeploymentPath,
    [string]$ApprovedBy = $env:GITHUB_ACTOR,
    [string]$RunId = $env:GITHUB_RUN_ID,
    [string]$OutputPath = 'approved-release-manifest.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.schema -ne 'release-manifest/v1') { throw "'$ManifestPath' is not a release manifest." }
$deployment = Get-Content -LiteralPath $QaDeploymentPath -Raw | ConvertFrom-Json
if ([string]$deployment.schema -ne 'environment-deployment/v1') { throw "'$QaDeploymentPath' is not an environment deployment record." }

if ([string]$deployment.candidateSha -ne [string]$manifest.candidateSha) {
    throw "QA deployed '$($deployment.candidateSha)' but the release identity is '$($manifest.candidateSha)'. Approval cannot be recorded."
}
if ([string]$deployment.releaseId -ne [string]$manifest.releaseId) {
    throw "QA deployed release '$($deployment.releaseId)' but the release identity is '$($manifest.releaseId)'. Approval cannot be recorded."
}

$deployed = @{}
foreach ($component in @($deployment.components)) { $deployed[[string]$component.component] = [string]$component.imageDigest }
foreach ($component in @($manifest.components)) {
    $name = [string]$component.component
    $digest = [string]$component.imageDigest
    if (-not $digest) { continue }
    if (-not $deployed.ContainsKey($name)) { throw "QA did not deploy component '$name'; it cannot be approved." }
    if ($deployed[$name] -ne $digest) {
        throw "QA deployed digest '$($deployed[$name])' for '$name' but the release identity records '$digest'. Approval cannot be recorded."
    }
}

$approved = [pscustomobject]@{
    schema = 'release-manifest/v1'
    releaseId = [string]$manifest.releaseId
    candidateSha = [string]$manifest.candidateSha
    channel = [string]$manifest.channel
    sourceBranch = [string]$manifest.sourceBranch
    repository = [string]$manifest.repository
    ciRunId = [string]$manifest.ciRunId
    generatedAt = [string]$manifest.generatedAt
    components = @($manifest.components)
    qaApproval = [pscustomobject]@{
        approvedBy = $ApprovedBy
        approvalRunId = $RunId
        approvedAt = [DateTime]::UtcNow.ToString('o')
        qaDeployment = (Resolve-Path -LiteralPath $QaDeploymentPath).Path
    }
}
$approved | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$approved | ConvertTo-Json -Depth 16
