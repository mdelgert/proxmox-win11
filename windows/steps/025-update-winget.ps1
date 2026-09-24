#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host '025: Updating WinGet using Microsoft.WinGet.Client.'

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12

Write-Host '025: Installing NuGet provider.'

Install-PackageProvider `
    -Name NuGet `
    -Force `
    -ForceBootstrap `
    -Scope AllUsers `
    -Confirm:$false | Out-Null

Write-Host '025: Installing Microsoft.WinGet.Client.'

Install-Module `
    -Name Microsoft.WinGet.Client `
    -Repository PSGallery `
    -Scope AllUsers `
    -Force `
    -AllowClobber `
    -Confirm:$false

Import-Module Microsoft.WinGet.Client -Force

Write-Host '025: Installing latest WinGet.'

Repair-WinGetPackageManager `
    -Latest `
    -Force `
    -AllUsers

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($null -eq $winget) {
    throw 'winget.exe is not available after Repair-WinGetPackageManager.'
}

$version = & winget.exe --version

if ($LASTEXITCODE -ne 0) {
    throw "winget --version failed with exit code $LASTEXITCODE"
}

Write-Host "025: WinGet ready: $version"