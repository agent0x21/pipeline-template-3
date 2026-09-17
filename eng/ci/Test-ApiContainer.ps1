[CmdletBinding()]
param(
    [string]$ConfigPath = '.releasepipeline.yml',
    [ValidateRange(1024, 65535)][int]$HostPort = 8088
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker is required. Install Docker Desktop and ensure the daemon is running.' }

Import-Module (Join-Path $PSScriptRoot 'ReleasePipeline/ReleasePipeline.psd1') -Force
$config = Import-ReleaseConfig $ConfigPath
if (-not $config.ContainsKey('validation') -or -not $config.validation.ContainsKey('containerSmoke')) {
    throw "Configuration '$ConfigPath' requires validation.containerSmoke to run a container smoke test."
}
$smoke = $config.validation.containerSmoke
if ($smoke -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$smoke.component) -or [string]::IsNullOrWhiteSpace([string]$smoke.path)) {
    throw 'validation.containerSmoke requires component and path.'
}
if (-not $config.components.ContainsKey([string]$smoke.component)) { throw "Container smoke test references unknown component '$($smoke.component)'." }
$component = $config.components[[string]$smoke.component]
if (-not $component.ContainsKey('publishing') -or [string]$component.publishing.adapter -ne 'container' -or [string]::IsNullOrWhiteSpace([string]$component.publishing.image)) {
    throw "Container smoke test component '$($smoke.component)' requires publishing.adapter 'container' and publishing.image."
}
$dockerfile = if ($component.publishing.dockerfile) { [string]$component.publishing.dockerfile } else { Join-Path ([string]$component.path) 'Dockerfile' }
$context = if ($component.publishing.context) { [string]$component.publishing.context } else { '.' }
$containerPort = if ($smoke.ContainsKey('containerPort')) { [int]$smoke.containerPort } else { 8080 }
if ($containerPort -lt 1 -or $containerPort -gt 65535) { throw 'validation.containerSmoke.containerPort must be between 1 and 65535.' }
$image = "$($component.publishing.image):smoke-$PID"
$containerName = "release-component-smoke-$PID"
try {
    & docker build '--file' $dockerfile '--tag' $image $context 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Container build failed for '$($smoke.component)'." }
    $runArguments = @('run', '--detach', '--rm', '--name', $containerName, '--publish', "127.0.0.1:${HostPort}:${containerPort}")
    if ($smoke.ContainsKey('environment')) {
        foreach ($name in $smoke.environment.Keys) { $runArguments += @('--env', "$name=$($smoke.environment[$name])") }
    }
    $runArguments += $image
    & docker @runArguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Container failed to start for '$($smoke.component)'." }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$HostPort$($smoke.path)" -TimeoutSec 3
            if ($response.StatusCode -eq 200) { Write-Host "Container smoke test passed for '$($smoke.component)': $image"; return }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Container '$($smoke.component)' did not return HTTP 200 from '$($smoke.path)' within 30 seconds."
} finally {
    & docker rm '--force' $containerName *> $null
}
