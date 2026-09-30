# 050-apps.ps1
$ErrorActionPreference = 'Stop'

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    Write-Host "Installing $Id..."

    & winget.exe install `
        --id $Id `
        --exact `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "winget failed installing $Id. Exit code: $LASTEXITCODE"
    }
}

if ($null -eq (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget.exe is not available.'
}

Install-WingetPackage '7zip.7zip'
Install-WingetPackage 'Git.Git'
Install-WingetPackage 'Microsoft.VisualStudioCode'