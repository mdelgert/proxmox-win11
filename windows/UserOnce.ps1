# Paste this script into the Unattend Generator's "UserOnce" section.
# It is intentionally small and stable: its only job is to download and run
# the public customization bootstrap from this repository.
#
# The bootstrap then owns logging, resume-after-reboot, step state, and cleanup.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$workRoot = Join-Path $env:ProgramData 'proxmox-win11'
$completeMarker = Join-Path $workRoot 'complete.marker'

# UserOnce can run for another newly-created user later. Once machine
# customization is complete, do nothing.
if (Test-Path -LiteralPath $completeMarker) {
    return
}

# Windows PowerShell 5.1 is available on a fresh Windows 11 installation.
# Force TLS 1.2 for older Windows PowerShell web requests.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$bootstrapUrl = 'https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1'
$bootstrapFile = Join-Path $env:TEMP 'proxmox-win11-bootstrap.ps1'

Invoke-WebRequest -UseBasicParsing -Uri $bootstrapUrl -OutFile $bootstrapFile
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrapFile
