<#
    Install the in-box OpenSSH server, start it, and open the firewall.
    No reboot is required, so this step always finishes with 0.
#>
. "$PSScriptRoot\_lib.ps1"

$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' |
    Select-Object -First 1

if ($capability.State -ne 'Installed') {
    Write-Info "Installing $($capability.Name) ..."
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
else {
    Write-Info 'OpenSSH server is already installed.'
}

Write-Info 'Setting sshd to start automatically.'
Set-Service -Name 'sshd' -StartupType Automatic
Start-Service -Name 'sshd'

if (-not (Get-NetFirewallRule -Name 'Win11Setup-SSH-In' -ErrorAction SilentlyContinue)) {
    Write-Info 'Opening TCP 22.'
    New-NetFirewallRule -Name 'Win11Setup-SSH-In' -DisplayName 'OpenSSH Server (Win11Setup)' `
        -Protocol TCP -LocalPort 22 -Direction Inbound -Action Allow | Out-Null
}

Write-Info ('sshd status: ' + (Get-Service -Name 'sshd').Status)
exit 0
