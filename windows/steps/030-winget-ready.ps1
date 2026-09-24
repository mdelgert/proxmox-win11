#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($null -eq $winget) {
    throw 'winget.exe is not available.'
}

Write-Host "WinGet version:"
& winget.exe --version

Write-Host 'Enabling WinGet Configuration...'

& winget.exe configure --enable

if ($LASTEXITCODE -ne 0) {
    throw "Unable to enable WinGet Configuration. Exit code: $LASTEXITCODE"
}

Write-Host 'WinGet Configuration is ready.'