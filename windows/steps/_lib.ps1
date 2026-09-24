<#
    Helpers shared by the step scripts. Dot-source it at the top of a step:

        . "$PSScriptRoot\_lib.ps1"

    Keep this file small and dependency free. It has to work on the Windows
    PowerShell 5.1 that ships with Windows 11, before anything is installed.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Info {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Write-Warn {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host ('{0}  WARNING: {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string] $Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

<#
    Installs a winget package if it is not already present.

    Returns $true when something was actually installed, so a step can decide
    whether it needs to ask for a reboot. Native command output is sent to the
    host on purpose: anything left on the output stream would be picked up by
    the caller instead of the boolean.
#>
function Install-WingetPackage {
    param([Parameter(Mandatory)][string] $Id)

    if (-not (Test-CommandExists 'winget')) { throw 'winget is not available yet.' }

    & winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "$Id is already installed."
        return $false
    }

    Write-Info "Installing $Id ..."
    & winget install --id $Id --exact --silent --disable-interactivity `
        --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "winget install $Id failed with exit code $LASTEXITCODE."
    }
    Write-Info "$Id installed."
    return $true
}
