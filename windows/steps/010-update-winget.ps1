#Requires -Version 5.1

# Updates WinGet to the latest stable release using Microsoft's documented
# method (Microsoft.WinGet.Client). Keep this step, and every step that uses
# winget, before any step that reboots: after a reboot the runner resumes as
# SYSTEM, where winget.exe is not on PATH.

$ErrorActionPreference = 'Stop'

Write-Host 'Updating WinGet to the latest stable release.'

Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Force
Repair-WinGetPackageManager -AllUsers -Latest -Force

$version = & winget.exe --version

if ($LASTEXITCODE -ne 0) {
    throw "winget --version failed with exit code $LASTEXITCODE"
}

Write-Host "WinGet ready: $version"
