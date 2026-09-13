[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pesterVersion = [version]'5.7.1'
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq $pesterVersion })) {
    throw "Pester $pesterVersion is required. Install it with: Install-Module Pester -RequiredVersion $pesterVersion -Scope CurrentUser"
}

Import-Module Pester -RequiredVersion $pesterVersion -Force
$result = Invoke-Pester (Join-Path $PSScriptRoot 'tests') -PassThru
if ($result.FailedCount -gt 0) {
    exit 1
}
