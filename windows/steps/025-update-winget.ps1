#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host '025: Updating/repairing WinGet.'

# PowerShell Gallery requires TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12

# Fresh Windows PowerShell 5.1 may not have the NuGet provider yet.
$nuget = Get-PackageProvider `
    -Name NuGet `
    -ListAvailable `
    -ErrorAction SilentlyContinue

if ($null -eq $nuget) {
    Write-Host '025: Installing NuGet package provider.'

    Install-PackageProvider `
        -Name NuGet `
        -MinimumVersion '2.8.5.201' `
        -Force `
        -ForceBootstrap `
        -Scope AllUsers `
        -Confirm:$false | Out-Null
}

# Import the provider into the current PowerShell session.
Import-PackageProvider `
    -Name NuGet `
    -Force `
    -ErrorAction Stop | Out-Null

Write-Host '025: Installing Microsoft.WinGet.Client module.'

Install-Module `
    -Name Microsoft.WinGet.Client `
    -Repository PSGallery `
    -Scope AllUsers `
    -Force `
    -AllowClobber `
    -Confirm:$false

Import-Module Microsoft.WinGet.Client -Force

Write-Host '025: Repairing/updating WinGet.'

Repair-WinGetPackageManager

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($null -eq $winget) {
    throw 'winget.exe is not available after Repair-WinGetPackageManager.'
}

$version = & winget.exe --version

if ($LASTEXITCODE -ne 0) {
    throw "winget --version failed with exit code $LASTEXITCODE"
}

Write-Host "025: WinGet ready: $version"