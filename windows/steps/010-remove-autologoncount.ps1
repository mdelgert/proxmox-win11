#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host 'Waiting for AutoLogonCount...'

$path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$name = 'AutoLogonCount'

$maxRetries = 60
$delaySeconds = 2

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {

    $item = Get-ItemProperty `
        -LiteralPath $path `
        -Name $name `
        -ErrorAction SilentlyContinue

    if ($null -ne $item) {

        Write-Host "AutoLogonCount found on attempt $attempt."

        Remove-ItemProperty `
            -LiteralPath $path `
            -Name $name `
            -Force

        Write-Host 'AutoLogonCount removed.'
        return
    }

    Start-Sleep -Seconds $delaySeconds
}

throw "AutoLogonCount did not appear after $($maxRetries * $delaySeconds) seconds."