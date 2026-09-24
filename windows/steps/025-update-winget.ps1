#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host '025: Updating WinGet / App Installer from official GitHub release.'

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12

$tempRoot = Join-Path $env:TEMP 'proxmox-win11-winget'
$depsRoot = Join-Path $tempRoot 'dependencies'

$releaseApi = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {

    Write-Host '025: Querying latest stable WinGet release.'

    $headers = @{
        'User-Agent' = 'proxmox-win11'
    }

    $release = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri $releaseApi `
        -Headers $headers

    Write-Host "025: Latest release: $($release.tag_name)"

    $bundleAsset = $release.assets |
        Where-Object {
            $_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        } |
        Select-Object -First 1

    $depsAsset = $release.assets |
        Where-Object {
            $_.name -eq 'DesktopAppInstaller_Dependencies.zip'
        } |
        Select-Object -First 1

    if ($null -eq $bundleAsset) {
        throw 'WinGet MSIX bundle was not found in the latest GitHub release.'
    }

    if ($null -eq $depsAsset) {
        throw 'WinGet dependency archive was not found in the latest GitHub release.'
    }

    $bundleFile = Join-Path $tempRoot $bundleAsset.name
    $depsFile   = Join-Path $tempRoot $depsAsset.name

    Write-Host '025: Downloading App Installer.'

    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $bundleAsset.browser_download_url `
        -OutFile $bundleFile

    Write-Host '025: Downloading App Installer dependencies.'

    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $depsAsset.browser_download_url `
        -OutFile $depsFile

    Remove-Item `
        -LiteralPath $depsRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Expand-Archive `
        -LiteralPath $depsFile `
        -DestinationPath $depsRoot `
        -Force

    # --------------------------------------------------------
    # Find x64 dependency packages from Microsoft's release.
    #
    # The exact dependency versions change over time, so do
    # not hardcode filenames.
    # --------------------------------------------------------

    $dependencyFiles = Get-ChildItem `
        -Path $depsRoot `
        -Recurse `
        -File |
        Where-Object {
            ($_.Extension -eq '.appx' -or $_.Extension -eq '.msix') -and
            (
                $_.FullName -match '\\x64\\' -or
                $_.Name -match '_x64'
            )
        }

    if ($dependencyFiles.Count -eq 0) {
        throw 'No x64 App Installer dependencies were found.'
    }

    Write-Host '025: Installing dependencies.'

    foreach ($dependency in $dependencyFiles) {

        Write-Host "025: Installing dependency: $($dependency.Name)"

        Add-AppxPackage `
            -Path $dependency.FullName `
            -ForceApplicationShutdown `
            -ErrorAction Stop
    }

    Write-Host '025: Installing/updating App Installer.'

    Add-AppxPackage `
        -Path $bundleFile `
        -ForceApplicationShutdown `
        -ForceUpdateFromAnyVersion `
        -ErrorAction Stop

    # Refresh command discovery in the current process.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') +
        ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue

    if ($null -eq $winget) {
        throw 'App Installer installed successfully, but winget.exe is not available in this session.'
    }

    $version = & winget.exe --version

    if ($LASTEXITCODE -ne 0) {
        throw "winget --version failed with exit code $LASTEXITCODE"
    }

    Write-Host "025: WinGet updated successfully: $version"
}
finally {

    Remove-Item `
        -LiteralPath $tempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}