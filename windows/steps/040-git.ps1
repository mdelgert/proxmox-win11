# 030-git.ps1
# Compatible with Windows PowerShell 5.1

$ErrorActionPreference = 'Stop'

Write-Host 'Checking for Git...'

$git = Get-Command git.exe -ErrorAction SilentlyContinue

if ($null -ne $git) {
    Write-Host "Git already installed: $(& git --version)"
    return
}

Write-Host 'Installing Git with winget...'

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($null -eq $winget) {
    throw 'winget.exe is not available yet.'
}

& winget.exe install `
    --id Git.Git `
    --exact `
    --silent `
    --accept-package-agreements `
    --accept-source-agreements `
    --disable-interactivity

if ($LASTEXITCODE -ne 0) {
    throw "winget failed installing Git. Exit code: $LASTEXITCODE"
}

# Refresh PATH for the current PowerShell process.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = "$machinePath;$userPath"

$git = Get-Command git.exe -ErrorAction SilentlyContinue

if ($null -eq $git) {
    throw 'Git installation completed, but git.exe is still not available.'
}

Write-Host "Installed: $(& git --version)"