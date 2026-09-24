# First customization step.
#
# Keep steps small and idempotent: it should be safe to run this script again
# if you delete its .done marker while debugging.
#
# The master bootstrap provides Request-Reboot. Call it only AFTER this step has
# completed all work that must happen before rebooting.

$ErrorActionPreference = 'Stop'

$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Host "Windows: $($os.Caption) $($os.Version)"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host 'Base customization runner is working.'

# Add only basic, low-risk machine-wide settings here.
# Put software/features into their own numbered step scripts instead.
