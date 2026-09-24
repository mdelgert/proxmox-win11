#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host '025: Ensuring WinGet is registered and ready.'

$pkg = Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $pkg) {
    throw 'Microsoft.DesktopAppInstaller is not installed.'
}

Write-Host "025: Latest installed App Installer: $($pkg.Version)"

$current = Get-AppxPackage Microsoft.DesktopAppInstaller |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (($null -eq $current) -or ($current.Version -ne $pkg.Version)) {

    Write-Host '025: Registering latest App Installer for current user.'

    $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'

    Add-AppxPackage `
        -DisableDevelopmentMode `
        -Register $manifest `
        -ForceApplicationShutdown

} else {

    Write-Host '025: Latest App Installer already registered.'
}

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($null -eq $winget) {
    throw 'winget.exe is not available.'
}

$version = & winget.exe --version

if ($LASTEXITCODE -ne 0) {
    throw "winget --version failed with exit code $LASTEXITCODE"
}

Write-Host "025: WinGet ready: $version"