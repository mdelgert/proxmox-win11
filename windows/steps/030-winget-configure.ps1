#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# Add or remove configuration files here.
$configNames = @(
    'baseline.dsc.winget'
    'ai-cli.winget'
)

foreach ($configName in $configNames) {

    $configUrl  = "$RawBase/.config/$configName"
    $configFile = Join-Path $Root $configName

    Write-Host ''
    Write-Host "Downloading WinGet configuration: $configName"

    Invoke-Download `
        -Uri $configUrl `
        -OutFile $configFile

    Write-Host "Applying WinGet configuration: $configName"

    & winget.exe configure `
        --file $configFile `
        --accept-configuration-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "winget configure failed for '$configName' with exit code $LASTEXITCODE"
    }

    Write-Host "Completed WinGet configuration: $configName"
}

Write-Host ''
Write-Host 'All WinGet configuration files completed successfully.'