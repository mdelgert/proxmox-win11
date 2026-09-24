#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host 'Configuring VS Code context menu.'

# Locate VS Code.
$codeExe = Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'

if (-not (Test-Path -LiteralPath $codeExe)) {
    $codeExe = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
}

if (-not (Test-Path -LiteralPath $codeExe)) {
    throw 'Could not find Code.exe. Install VS Code first.'
}

Write-Host "Found VS Code: $codeExe"

# ------------------------------------------------------------
# Folder context menu
# Right-click a folder -> Open with Code
# ------------------------------------------------------------

$folderKey = 'Registry::HKEY_CLASSES_ROOT\Directory\shell\VSCode'
$folderCommandKey = "$folderKey\command"

New-Item -Path $folderKey -Force | Out-Null

Set-ItemProperty `
    -Path $folderKey `
    -Name '(Default)' `
    -Value 'Open with Code' `
    -Force

Set-ItemProperty `
    -Path $folderKey `
    -Name 'Icon' `
    -Value "`"$codeExe`"" `
    -Force

New-Item -Path $folderCommandKey -Force | Out-Null

Set-ItemProperty `
    -Path $folderCommandKey `
    -Name '(Default)' `
    -Value "`"$codeExe`" `"%V`"" `
    -Force


# ------------------------------------------------------------
# Folder background context menu
# Right-click inside a folder -> Open with Code
# ------------------------------------------------------------

$backgroundKey = 'Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\VSCode'
$backgroundCommandKey = "$backgroundKey\command"

New-Item -Path $backgroundKey -Force | Out-Null

Set-ItemProperty `
    -Path $backgroundKey `
    -Name '(Default)' `
    -Value 'Open with Code' `
    -Force

Set-ItemProperty `
    -Path $backgroundKey `
    -Name 'Icon' `
    -Value "`"$codeExe`"" `
    -Force

New-Item -Path $backgroundCommandKey -Force | Out-Null

Set-ItemProperty `
    -Path $backgroundCommandKey `
    -Name '(Default)' `
    -Value "`"$codeExe`" `"%V`"" `
    -Force


# ------------------------------------------------------------
# Refresh Explorer
# ------------------------------------------------------------

Write-Host 'Restarting Explorer to refresh context menus.'

Get-Process explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force

Start-Process explorer.exe

Write-Host 'VS Code context menu configured successfully.'