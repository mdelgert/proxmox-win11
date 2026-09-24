#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host '025: Updating WinGet / App Installer.'

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($null -eq $winget) {
    throw 'winget.exe is not available.'
}

Write-Host "Current WinGet version: $(& winget.exe --version)"

& winget.exe upgrade `
    Microsoft.AppInstaller `
    --accept-source-agreements `
    --accept-package-agreements `
    --disable-interactivity

if ($LASTEXITCODE -ne 0) {
    throw "App Installer update failed with exit code $LASTEXITCODE"
}

Write-Host "Updated WinGet version: $(& winget.exe --version)"