#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host 'Configuring Git.'

# Git is installed by 030-winget-configure, in the same process that runs this
# step. That process inherited its PATH at launch, before Git existed, and
# Windows never updates a running process's environment. bootstrap.ps1 rebuilds
# $env:Path after every step, but PowerShell also caches command discovery, so
# fall back to the known install locations instead of trusting Get-Command.
$gitExe = $null

$command = Get-Command 'git.exe' -ErrorAction SilentlyContinue

if ($null -ne $command) {
    $gitExe = $command.Source
}
else {
    $candidates = @()

    if ($env:ProgramFiles) {
        $candidates += ( Join-Path $env:ProgramFiles 'Git\cmd\git.exe' )
    }

    if (${env:ProgramFiles(x86)}) {
        $candidates += ( Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe' )
    }

    if ($env:LOCALAPPDATA) {
        $candidates += ( Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe' )
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $gitExe = $candidate
            break
        }
    }
}

if ($null -eq $gitExe) {
    throw 'git.exe is not available. Install Git before this step.'
}

Write-Host "Using Git: $gitExe"

$userName  = 'Matthew Elgert'
$userEmail = 'mdelgert@yahoo.com'

& $gitExe config --global user.name $userName

if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure Git user.name.'
}

& $gitExe config --global user.email $userEmail

if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure Git user.email.'
}

Write-Host "Git user.name  = $(& $gitExe config --global user.name)"
Write-Host "Git user.email = $(& $gitExe config --global user.email)"

Write-Host 'Git configuration completed.'
