# 999-complete.ps1
# Final provisioning step.
# Compatible with Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'

Write-Host '999: Finalizing Windows customization.'

# The bootstrap runner defines this function before invoking step scripts.
Disable-SetupAutoLogon

$root = 'C:\ProgramData\proxmox-win11'
$completionFile = Join-Path $root 'customization-complete.txt'
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$content = @"
Windows 11 customization completed successfully.

Computer: $env:COMPUTERNAME
Completed: $timestamp
Runner: proxmox-win11
"@

Set-Content `
    -LiteralPath $completionFile `
    -Value $content `
    -Encoding UTF8

Write-Host ''
Write-Host '=============================================='
Write-Host ' Windows customization completed successfully'
Write-Host '=============================================='
Write-Host ''
Write-Host "Computer:  $env:COMPUTERNAME"
Write-Host "Completed: $timestamp"
Write-Host 'Temporary setup autologon has been disabled.'