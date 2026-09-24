# 060-reboot-test.ps1
# Purpose:
#   Verify that a completed step can request a reboot and that
#   provisioning resumes automatically after Windows starts again.

$ErrorActionPreference = 'Stop'

Write-Host '060: Reboot test starting.'

$marker = 'C:\ProgramData\proxmox-win11\060-before-reboot.txt'

Set-Content `
    -Path $marker `
    -Value "060 completed before reboot at $(Get-Date)"

Write-Host "060: Wrote marker: $marker"
Write-Host '060: Requesting reboot.'

Request-Reboot