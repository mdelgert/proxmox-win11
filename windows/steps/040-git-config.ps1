#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host 'Configuring Git.'

$git = Get-Command git.exe -ErrorAction SilentlyContinue

if ($null -eq $git) {
    throw 'git.exe is not available. Install Git before this step.'
}

$userName  = 'Matthew Elgert'
$userEmail = 'mdelgert@yahoo.com'

& git.exe config --global user.name $userName

if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure Git user.name.'
}

& git.exe config --global user.email $userEmail

if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure Git user.email.'
}

Write-Host "Git user.name  = $(& git.exe config --global user.name)"
Write-Host "Git user.email = $(& git.exe config --global user.email)"

Write-Host 'Git configuration completed.'