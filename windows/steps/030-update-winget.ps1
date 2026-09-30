#Requires -Version 5.1

# Makes winget usable for the steps that follow. The contract of this step is
# capability, not a version number.
#
# The previous implementation called
#     Repair-WinGetPackageManager -AllUsers -Latest -Force
# which asserts that the installed winget equals the version the
# Microsoft.WinGet.Client module expects. On a fresh Windows 11 image that
# assertion failed and took the whole run down:
#     "The installed winget version doesn't match the expectation.
#      Installer version 'v1.9.25200' Expected version 'v1.29.380'"
# -AllUsers provisions App Installer machine-wide but does not re-register it
# for the already logged-on user, so the check compared the still-current
# in-box build against the expected new one.
#
# An upgrade is still attempted, but it can no longer fail the run: the in-box
# build is normally new enough for 'winget configure'. 030-winget-ready is the
# gate that decides whether winget can actually do the work.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The app execution alias. Testing the file directly avoids Get-Command's
# command cache, which can keep reporting winget.exe as missing.
$aliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'

function Test-WinGetPresent {
    if (Test-Path -LiteralPath $aliasPath) {
        return $true
    }

    return $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)
}

function Get-WinGetVersion {
    # Soft probe: a present-but-unregistered alias throws instead of exiting
    # non-zero, and that must not fail the step before the upgrade is tried.
    try {
        return ( & winget.exe --version | Out-String ).Trim()
    }
    catch {
        return "not runnable ($($_.Exception.Message))"
    }
}

# At first logon the per-user registration of App Installer can still be in
# flight, so allow a short grace period instead of failing immediately.
$maxRetries = 20
$delaySeconds = 3

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    if (Test-WinGetPresent) {
        break
    }

    Write-Host "winget.exe is not available yet (attempt $attempt/$maxRetries)."
    Start-Sleep -Seconds $delaySeconds
}

if (-not (Test-WinGetPresent)) {
    throw "winget.exe did not appear after $($maxRetries * $delaySeconds) seconds."
}

Write-Host "WinGet before upgrade: $(Get-WinGetVersion)"

# aka.ms/getwinget always redirects to the current App Installer bundle.
# Add-AppxPackage makes no version assertion, so a mismatch cannot fail the
# run the way Repair-WinGetPackageManager did. Missing framework dependencies
# on an image without Store access land in the catch and are reported.
try {
    $bundle = Join-Path $env:TEMP 'Microsoft.DesktopAppInstaller.msixbundle'

    Write-Host 'Attempting to upgrade App Installer from https://aka.ms/getwinget'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri 'https://aka.ms/getwinget' `
        -OutFile $bundle

    Add-AppxPackage -Path $bundle

    Write-Host 'App Installer upgrade applied.'
}
catch {
    Write-Host "App Installer upgrade skipped: $($_.Exception.Message)"
    Write-Host 'Continuing with the in-box version.'
}

# The only fatal condition: winget has to run.
try {
    $version = ( & winget.exe --version | Out-String ).Trim()
}
catch {
    throw "winget.exe could not be started: $($_.Exception.Message)"
}

if ($LASTEXITCODE -ne 0) {
    throw "winget --version failed with exit code $LASTEXITCODE"
}

Write-Host "WinGet in use: $version"
