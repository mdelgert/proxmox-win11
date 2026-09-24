# 999-complete.ps1
# Final placeholder step for the Windows customization pipeline.
#
# Purpose:
#   - Confirm all previous customization steps completed.
#   - Write a human-readable completion file.
#   - Leave a simple breadcrumb for troubleshooting.
#
# Compatible with Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'

Write-Host '999: Final customization step starting.'

$root = 'C:\ProgramData\proxmox-win11'
$completionFile = Join-Path $root 'customization-complete.txt'

$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$content = @"
Windows 11 customization completed successfully.

Computer: $computerName
Completed: $timestamp
Runner: proxmox-win11
"@

Set-Content `
    -Path $completionFile `
    -Value $content `
    -Encoding UTF8

Write-Host ''
Write-Host '=============================================='
Write-Host ' Windows customization completed successfully'
Write-Host '=============================================='
Write-Host ''
Write-Host "Computer:   $computerName"
Write-Host "Completed:  $timestamp"
Write-Host "Marker:     $completionFile"
Write-Host ''