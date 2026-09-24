<#
    Baseline machine settings.

    Exit codes: 0 = done, 3010 = done + reboot, 3011 = reboot + run me again.
#>
. "$PSScriptRoot\_lib.ps1"

# Set to a name to rename the machine, or leave empty to keep the random name
# Windows Setup generated. A rename needs a reboot, which is a good example of
# a step that finishes with 3010.
$NewComputerName = ''

Write-Info 'Disabling sleep, hibernation and display timeout.'
powercfg.exe /change standby-timeout-ac 0
powercfg.exe /change monitor-timeout-ac 0
powercfg.exe /hibernate off

Write-Info 'Enabling long path support.'
Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
    -Name 'LongPathsEnabled' -Value 1 -Type DWord -Force

Write-Info 'Allowing ICMP so the VM answers pings.'
$rule = 'Win11Setup-ICMPv4-In'
if (-not (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $rule -DisplayName 'Allow ICMPv4 ping (Win11Setup)' `
        -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow | Out-Null
}

if ($NewComputerName -and $env:COMPUTERNAME -ne $NewComputerName) {
    Write-Info "Renaming this machine to $NewComputerName."
    Rename-Computer -NewName $NewComputerName -Force
    exit 3010
}

Write-Info 'Baseline settings applied.'
exit 0
