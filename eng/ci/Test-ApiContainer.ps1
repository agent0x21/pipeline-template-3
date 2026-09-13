[CmdletBinding()]
param(
    [string]$Image = 'pipeline-template-api:test',
    [ValidateRange(1024, 65535)][int]$HostPort = 8088
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker is required. Install Docker Desktop and ensure the daemon is running.' }

$containerName = "pipeline-template-api-smoke-$PID"
try {
    & docker build '--file' 'apps/api/Dockerfile' '--tag' $Image '.' 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'API container build failed.' }
    & docker run '--detach' '--rm' '--name' $containerName '--publish' "127.0.0.1:${HostPort}:8080" '--env' 'ASPNETCORE_URLS=http://+:8080' $Image 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'API container failed to start.' }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$HostPort/weatherforecast" -TimeoutSec 3
            if ($response.StatusCode -eq 200) { Write-Host "API container smoke test passed: $Image"; return }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "API container did not return HTTP 200 from /weatherforecast within 30 seconds."
} finally {
    & docker rm '--force' $containerName *> $null
}
