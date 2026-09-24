<#
    Make sure winget (the App Installer package) is present and working.

    A brand new user profile sometimes has the package registered but not yet
    initialised, so this retries before falling back to a direct download.
#>
. "$PSScriptRoot\_lib.ps1"

function Test-Winget {
    if (-not (Test-CommandExists 'winget')) { return $false }
    & winget --version 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-Winget)) {
    Write-Info 'winget not responding yet; re-registering the App Installer package.'
    Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction SilentlyContinue |
        ForEach-Object {
            Add-AppxPackage -DisableDevelopmentMode -Register `
                "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
        }
}

# The Store can still be updating the package during the first few minutes.
for ($attempt = 1; $attempt -le 10 -and -not (Test-Winget); $attempt++) {
    Write-Info "Waiting for winget to become available ($attempt/10) ..."
    Start-Sleep -Seconds 15
}

if (-not (Test-Winget)) {
    Write-Info 'Installing App Installer directly from aka.ms/getwinget.'
    $bundle = Join-Path $env:TEMP 'DesktopAppInstaller.msixbundle'
    Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing -TimeoutSec 300
    Add-AppxPackage -Path $bundle
    Remove-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Winget)) { throw 'winget is still unavailable; look at this step log.' }

Write-Info ('winget version: ' + (& winget --version))
& winget source update --disable-interactivity 2>&1 | Out-Host

exit 0
