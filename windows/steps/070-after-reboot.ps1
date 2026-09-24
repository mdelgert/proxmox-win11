# 070-after-reboot.ps1
# Purpose:
#   Confirm the runner resumed after the reboot requested by 060.

$ErrorActionPreference = 'Stop'

Write-Host '070: Resume-after-reboot test starting.'

$beforeMarker = 'C:\ProgramData\proxmox-win11\060-before-reboot.txt'
$afterMarker  = 'C:\ProgramData\proxmox-win11\070-after-reboot.txt'

if (-not (Test-Path -LiteralPath $beforeMarker)) {
    throw "Expected marker from step 060 was not found: $beforeMarker"
}

Set-Content `
    -Path $afterMarker `
    -Value "070 resumed successfully after reboot at $(Get-Date)"

Write-Host '070: Resume-after-reboot test succeeded.'
Write-Host "070: Wrote marker: $afterMarker"