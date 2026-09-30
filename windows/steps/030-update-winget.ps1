#Requires -Version 5.1

# Ensures winget can run DSC configurations, which is what 030-winget-configure
# needs. The contract of this step is capability, not a version number.
#
# Why this is more than a version check:
#   A fresh Windows 11 image ships App Installer v1.9.x, and on that build
#   'winget configure --enable' has to download the configuration components
#   from the Store. Seconds into the first logon that download fails:
#       Enabling configuration components. Requires store access.
#       ... 95%
#       exit code 1
#   Windows services App Installer to a current build on its own within the
#   hour, and from v1.29 onwards '--enable' is a local setting that returns
#   immediately. Provisioning starts far too early to wait for that, so this
#   step upgrades App Installer itself when it has to.
#
#   That upgrade needs a framework a fresh image does not carry:
#       0x80073CF3 ... depends on a framework that could not be found.
#       Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0
#   so the release's own dependency archive is installed alongside the bundle
#   instead of hoping the framework is present.
#
# About 315 MB is downloaded, but only when the installed winget cannot enable
# configuration. On a machine Windows has already serviced, nothing is fetched.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# bootstrap.ps1 defines $Root. Fall back to the same location so this step can
# still be run on its own for troubleshooting.
$rootVariable = Get-Variable -Name 'Root' -ErrorAction SilentlyContinue

if ($null -ne $rootVariable -and $rootVariable.Value) {
    $workRoot = $rootVariable.Value
}
else {
    $workRoot = Join-Path $env:ProgramData 'proxmox-win11'
}

$downloadDir = Join-Path $workRoot 'cache'

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

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
    # Soft probe. A present-but-unregistered alias throws rather than exiting
    # non-zero, and that must not fail the step before an upgrade is tried.
    try {
        return ( & winget.exe --version | Out-String ).Trim()
    }
    catch {
        return "not runnable ($($_.Exception.Message))"
    }
}

function Enable-WinGetConfiguration {
    # $true when 'winget configure' is usable. Output is captured rather than
    # left on the success stream, so it cannot contaminate the return value.
    try {
        $output = & winget.exe configure --enable
    }
    catch {
        Write-Host "configure --enable could not run: $($_.Exception.Message)"
        return $false
    }

    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        Write-Host $line
    }

    if ($exitCode -eq 0) {
        return $true
    }

    Write-Host "configure --enable exited with $exitCode."
    return $false
}

function Get-Asset {
    # These downloads are ~300 MB together, so a file already in the cache at
    # the expected size is reused rather than fetched again. That matters for
    # a rerun or a -OnlyStep retry.
    param(
        [Parameter( Mandatory = $true )] $Asset,
        [Parameter( Mandatory = $true )] [string] $Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        $existing = Get-Item -LiteralPath $Destination

        if ($existing.Length -eq $Asset.size) {
            Write-Host "Using cached $($Asset.name)."
            return
        }

        Write-Host "Cached $($Asset.name) is the wrong size; downloading again."
    }

    Write-Host "Downloading $($Asset.name) ($([math]::Round($Asset.size / 1MB)) MB)."

    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $Asset.browser_download_url `
        -OutFile $Destination
}

function Update-AppInstaller {
    # Installs the current App Installer from the winget-cli release together
    # with that same release's dependency archive, so the framework versions
    # match the bundle instead of being assumed.

    $headers = @{ 'User-Agent' = 'proxmox-win11' }

    Write-Host 'Resolving the latest winget-cli release.'

    $release = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
        -Headers $headers `
        -TimeoutSec 60

    Write-Host "Release: $($release.tag_name)"

    $bundleAsset = $release.assets |
        Where-Object { $_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' } |
        Select-Object -First 1

    $dependencyAsset = $release.assets |
        Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } |
        Select-Object -First 1

    if ($null -eq $bundleAsset) {
        throw 'The winget-cli release does not contain Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle.'
    }

    if ($null -eq $dependencyAsset) {
        throw 'The winget-cli release does not contain DesktopAppInstaller_Dependencies.zip.'
    }

    $bundlePath = Join-Path $downloadDir $bundleAsset.name
    $archivePath = Join-Path $downloadDir $dependencyAsset.name
    $extractDir = Join-Path $downloadDir 'DesktopAppInstaller_Dependencies'

    Get-Asset -Asset $bundleAsset -Destination $bundlePath
    Get-Asset -Asset $dependencyAsset -Destination $archivePath

    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }

    Write-Host 'Extracting dependency packages.'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractDir)

    # The archive carries every architecture. Only the x64 frameworks apply.
    $dependencies = @(
        Get-ChildItem -LiteralPath $extractDir -Recurse -Include '*.appx', '*.msix' |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Select-Object -ExpandProperty FullName
    )

    if ($dependencies.Count -eq 0) {
        throw "No x64 dependency packages were found under $extractDir."
    }

    foreach ($dependency in $dependencies) {
        Write-Host "Dependency: $(Split-Path -Leaf $dependency)"
    }

    Write-Host 'Installing App Installer.'
    Add-AppxPackage -Path $bundlePath -DependencyPath $dependencies

    # The app execution alias needs a moment to resolve to the new package.
    Start-Sleep -Seconds 5
}

# 1. winget has to exist at all. At first logon the per-user registration of
#    App Installer can still be in flight, so allow a short grace period.
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

Write-Host "WinGet present: $(Get-WinGetVersion)"

# 2. Cheapest path: the installed build can already enable configuration.
if (Enable-WinGetConfiguration) {
    Write-Host 'WinGet configuration is enabled. No upgrade required.'
    return
}

# 3. Otherwise upgrade App Installer and try once more.
Write-Host 'Upgrading App Installer so that configuration can be enabled.'

Update-AppInstaller

Write-Host "WinGet after upgrade: $(Get-WinGetVersion)"

if (-not (Enable-WinGetConfiguration)) {
    throw "WinGet configuration could not be enabled after upgrading App Installer (winget $(Get-WinGetVersion))."
}

Write-Host 'WinGet configuration is enabled.'
