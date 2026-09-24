#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host '025: Updating/repairing WinGet.'

# Ensure NuGet provider exists.
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider `
        -Name NuGet `
        -Force `
        -Scope AllUsers
}

# Install the Microsoft WinGet PowerShell module if needed.
if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
    Install-Module `
        -Name Microsoft.WinGet.Client `
        -Repository PSGallery `
        -Force `
        -Scope AllUsers
}

Import-Module Microsoft.WinGet.Client -Force

Write-Host 'Repairing/updating WinGet package manager...'

Repair-WinGetPackageManager

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($null -eq $winget) {
    throw 'winget.exe is still not available after repair.'
}

$version = & winget.exe --version

if ($LASTEXITCODE -ne 0) {
    throw "winget --version failed with exit code $LASTEXITCODE"
}

Write-Host "025: WinGet ready: $version"