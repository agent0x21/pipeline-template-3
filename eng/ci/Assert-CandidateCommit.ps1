[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedSha,
    [string]$Branch = '',
    [string]$Commit = 'HEAD',
    [string]$OutputPath = 'candidate.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force

$candidateSha = Assert-CandidateCommit -ExpectedSha $ExpectedSha -Commit $Commit
$candidate = [pscustomobject]@{
    candidateSha = $candidateSha
    shortSha = Get-ShortSha $candidateSha
    sourceBranch = $Branch
    verifiedAt = [DateTime]::UtcNow.ToString('o')
}
$candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$candidate | ConvertTo-Json -Depth 8
