#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host '050: Installing Hermes Agent.'

# Ensure TLS 1.2 for HTTPS downloads on Windows PowerShell 5.1.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12

# Skip if Hermes is already installed.
$hermes = Get-Command hermes.exe -ErrorAction SilentlyContinue

if ($null -ne $hermes) {
    Write-Host "050: Hermes already installed: $($hermes.Source)"
    return
}

Write-Host '050: Downloading official Hermes installer.'

$installerUrl = 'https://hermes-agent.nousresearch.com/install.ps1'
$installer = Invoke-RestMethod -Uri $installerUrl

Write-Host '050: Running Hermes installer.'

Invoke-Expression $installer

# Refresh PATH for this PowerShell process.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = "$machinePath;$userPath"

$hermes = Get-Command hermes.exe -ErrorAction SilentlyContinue

if ($null -eq $hermes) {
    # The installer may have updated PATH for future sessions only.
    Write-Host '050: Hermes installation completed, but the command is not visible in this session yet.'
    Write-Host '050: A new login/session may be required.'
    return
}

Write-Host "050: Hermes installed: $($hermes.Source)"

& hermes.exe --version

Write-Host '050: Hermes installation completed.'