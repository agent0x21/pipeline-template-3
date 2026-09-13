[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [string]$OutputPath = 'registry-publication.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

function Invoke-External([string]$File, [string[]]$Arguments, [string]$Description) {
    & $File @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

$results = foreach ($publication in @($plan.publications)) {
    $path = [IO.Path]::GetFullPath([string]$publication.artifactPath)
    if ($publication.adapter -ne 'container' -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Registry artifact not found: $path" }
    $description = "$($publication.adapter) publication for $($publication.component) $($publication.semanticVersion)"
    if ($publication.oidc -and -not $publication.tokenEnvironmentVariable) {
        Write-Verbose "$description expects workload identity; the CI provider must authenticate before this step."
    }
    if ($PSCmdlet.ShouldProcess($description)) {
        switch ([string]$publication.adapter) {
            'nuget' {
                $args = @('nuget','push',$path,'--source',[string]$publication.endpoint,'--skip-duplicate')
                Invoke-External 'dotnet' $args $description
            }
            'npm' {
                $args = @('publish',$path,'--registry',[string]$publication.endpoint,'--provenance')
                Invoke-External 'npm' $args $description
            }
            'container' {
                $tag = "{0}:{1}" -f [string]$publication.image, [string]$publication.semanticVersion
                Invoke-External 'docker' @('tag',[string]$publication.artifactPath,$tag) $description
                Invoke-External 'docker' @('push',$tag) $description
            }
            default { throw "Unsupported registry adapter '$($publication.adapter)'." }
        }
        [pscustomobject]@{ component = $publication.component; adapter = $publication.adapter; semanticVersion = $publication.semanticVersion; status = 'published'; sha256 = $publication.sha256 }
    } else {
        [pscustomobject]@{ component = $publication.component; adapter = $publication.adapter; semanticVersion = $publication.semanticVersion; status = 'planned'; sha256 = $publication.sha256 }
    }
}
$record = [pscustomobject]@{ plan = $plan; publications = @($results); generatedAt = [DateTime]::UtcNow.ToString('o') }
$record | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$record | ConvertTo-Json -Depth 16
