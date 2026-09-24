# Install and enable the built-in Windows OpenSSH Server.
#
# OpenSSH Server ships as a Windows optional capability (Features on Demand),
# so no third-party installer or package manager is required. This step needs
# internet access unless the capability source is already available locally.
#
# The step is idempotent: it only installs what is missing and always verifies
# the final state before returning. No reboot is required.

$ErrorActionPreference = 'Stop'

$ServiceName = 'sshd'
$FirewallRuleName = 'OpenSSH-Server-In-TCP'

Write-Host 'Installing OpenSSH Server...'

# Capability names are versioned (for example OpenSSH.Server~~~~0.0.1.0), so
# match on the prefix instead of hardcoding a version.
$capability = Get-WindowsCapability -Online |
    Where-Object { $_.Name -like 'OpenSSH.Server*' } |
    Select-Object -First 1

if ($null -eq $capability) {
    throw 'The OpenSSH.Server Windows capability is not available on this system.'
}

if ($capability.State -eq 'Installed') {
    Write-Host "OpenSSH Server capability is already installed: $($capability.Name)"
}
else {
    Write-Host "Adding Windows capability: $($capability.Name)"
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}

# Re-query rather than trusting the pre-install object.
$capability = Get-WindowsCapability -Online -Name $capability.Name

if ($capability.State -ne 'Installed') {
    throw "OpenSSH Server capability install failed. Current state: $($capability.State)"
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($null -eq $service) {
    throw "The '$ServiceName' service was not found after installing the OpenSSH Server capability."
}

# The capability installs sshd as Manual by default.
Set-Service -Name $ServiceName -StartupType Automatic

if ($service.Status -ne 'Running') {
    Write-Host "Starting the '$ServiceName' service..."
    Start-Service -Name $ServiceName
}

# The capability normally creates this rule, but it can be missing on images
# with customized firewall policy.
$rule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue

if ($null -eq $rule) {
    Write-Host "Creating firewall rule: $FirewallRuleName"

    New-NetFirewallRule `
        -Name $FirewallRuleName `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Description 'Inbound rule for OpenSSH Server (sshd).' `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22 `
        -Profile Any | Out-Null
}
elseif (-not $rule.Enabled) {
    Write-Host "Enabling firewall rule: $FirewallRuleName"
    Enable-NetFirewallRule -Name $FirewallRuleName
}

# Use PowerShell instead of cmd.exe for interactive SSH sessions. This is a
# machine-wide OpenSSH setting and is safe to reapply.
$sshRegistryKey = 'HKLM:\SOFTWARE\OpenSSH'
$defaultShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (Test-Path -LiteralPath $sshRegistryKey) {
    New-ItemProperty `
        -LiteralPath $sshRegistryKey `
        -Name 'DefaultShell' `
        -Value $defaultShell `
        -PropertyType String `
        -Force | Out-Null

    Write-Host "Default SSH shell set to: $defaultShell"
}

# Verify the desired end state instead of assuming the commands above worked.
$service = Get-Service -Name $ServiceName

if ($service.Status -ne 'Running') {
    throw "The '$ServiceName' service is not running. Current status: $($service.Status)"
}

if ($service.StartType -ne 'Automatic') {
    throw "The '$ServiceName' service start type is '$($service.StartType)' instead of 'Automatic'."
}

Write-Host 'OpenSSH Server is installed, running, and set to start automatically.'
