#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$configName = 'baseline.dsc.winget'
$configUrl  = "$RawBase/.config/$configName"
$configFile = Join-Path $Root $configName

Write-Host "Downloading WinGet configuration: $configName"

Invoke-Download `
    -Uri $configUrl `
    -OutFile $configFile

Write-Host 'Applying WinGet configuration...'

& winget.exe configure `
    --file $configFile `
    --accept-configuration-agreements `
    --disable-interactivity

if ($LASTEXITCODE -ne 0) {
    throw "winget configure failed with exit code $LASTEXITCODE"
}

Write-Host 'WinGet configuration completed successfully.'