# 070-after-reboot.ps1
# Purpose:
#   Confirm the runner resumed after the reboot.

$ErrorActionPreference = 'Stop'

Write-Host 'Resume-after-reboot test starting.'

$beforeMarker = 'C:\ProgramData\proxmox-win11\060-before-reboot.txt'
$afterMarker  = 'C:\ProgramData\proxmox-win11\070-after-reboot.txt'

if (-not (Test-Path -LiteralPath $beforeMarker)) {
    throw "Expected marker from step 060 was not found: $beforeMarker"
}

Set-Content `
    -Path $afterMarker `
    -Value "resumed successfully after reboot at $(Get-Date)"

Write-Host 'Resume-after-reboot test succeeded.'
Write-Host "Wrote marker: $afterMarker"