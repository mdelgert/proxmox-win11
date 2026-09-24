#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host 'Setting active network profile to Private.'

$profiles = Get-NetConnectionProfile |
    Where-Object {
        $_.IPv4Connectivity -ne 'Disconnected' -or
        $_.IPv6Connectivity -ne 'Disconnected'
    }

if (-not $profiles) {
    throw 'No active network connection profile was found.'
}

foreach ($profile in $profiles) {

    Write-Host "Adapter: $($profile.InterfaceAlias)"
    Write-Host "Current category: $($profile.NetworkCategory)"

    if ($profile.NetworkCategory -ne 'Private') {

        Set-NetConnectionProfile `
            -InterfaceIndex $profile.InterfaceIndex `
            -NetworkCategory Private

        Write-Host "Set $($profile.InterfaceAlias) to Private."
    }
    else {
        Write-Host "$($profile.InterfaceAlias) is already Private."
    }
}

Write-Host 'Network profile configuration completed.'