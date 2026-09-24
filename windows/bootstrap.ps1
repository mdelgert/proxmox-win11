<#
.SYNOPSIS
    Resumable Windows 11 post-install customization runner.

.DESCRIPTION
    This script is the single stable entry point called from Autounattend.xml.

    It is intentionally compatible with Windows PowerShell 5.1 so it can run
    immediately on a fresh Windows 11 installation without requiring PowerShell 7.

    Responsibilities:
      - verify elevated/admin execution
      - disable Windows Setup autologon after the first successful bootstrap
      - copy itself to C:\ProgramData\proxmox-win11
      - register a SYSTEM startup task so reboots can resume without autologon
      - download customization steps from GitHub
      - skip completed steps using simple .done marker files
      - keep a transcript log
      - reboot only when a completed step explicitly requests one
      - remove the startup task and write complete.marker when all steps finish

    Individual step scripts should be small, idempotent, and throw on failure.
    A step may call Request-Reboot after it has completed work that requires a
    reboot before the next step is allowed to run.
#>

[CmdletBinding()]
param(
    [string]$RepoOwner = 'mdelgert',
    [string]$RepoName = 'proxmox-win11',
    [string]$RepoRef = 'main',
    [switch]$ResetState,
    [switch]$NoReboot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$TaskName = 'ProxmoxWin11-Customize'
$Root = Join-Path $env:ProgramData 'proxmox-win11'
$StateDir = Join-Path $Root 'state'
$CacheDir = Join-Path $Root 'cache'
$LogDir = Join-Path $Root 'logs'
$LocalBootstrap = Join-Path $Root 'bootstrap.ps1'
$CompleteMarker = Join-Path $Root 'complete.marker'
$RebootMarker = Join-Path $StateDir 'reboot.requested'
$LogFile = Join-Path $LogDir 'customize.log'
$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoRef"

# Keep the list small and explicit. Add one entry per customization step.
# Steps run in this order. A .done marker is created only after a step returns
# successfully. Start with 010-base.ps1, prove the runner, then add one step at
# a time (OpenSSH, Git, applications, updates, and so on).
$Steps = @(
    @{ Name = '010-base'; Path = 'windows/steps/010-base.ps1' }
)

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$stamp] $Message"
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Disable-SetupAutoLogon {
    # Windows Setup may use Winlogon autologon to reach the first desktop.
    # We no longer need autologon after this bootstrap starts because resume is
    # handled by a SYSTEM startup scheduled task.
    $key = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

    & reg.exe add $key /v AutoAdminLogon /t REG_SZ /d 0 /f | Out-Null
    & reg.exe delete $key /v AutoLogonCount /f 2>$null | Out-Null
    & reg.exe delete $key /v DefaultPassword /f 2>$null | Out-Null

    Write-Log 'Disabled setup autologon and removed AutoLogonCount/DefaultPassword when present.'
}

function Install-ResumeTask {
    # Run 30 seconds after every boot as SYSTEM. The delay gives networking and
    # normal Windows services time to initialize before a step downloads from GitHub.
    $taskCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$LocalBootstrap`" -RepoOwner `"$RepoOwner`" -RepoName `"$RepoName`" -RepoRef `"$RepoRef`""

    & schtasks.exe /Create /TN $TaskName /SC ONSTART /DELAY 0000:30 /RU SYSTEM /RL HIGHEST /TR $taskCommand /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create scheduled task '$TaskName'."
    }

    Write-Log "Installed startup resume task '$TaskName'."
}

function Remove-ResumeTask {
    & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
    Write-Log "Removed startup resume task '$TaskName'."
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    $attempts = 6
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
            return
        }
        catch {
            if ($attempt -eq $attempts) {
                throw
            }
            Write-Log "Download attempt $attempt/$attempts failed; retrying in 10 seconds: $Uri"
            Start-Sleep -Seconds 10
        }
    }
}

function Request-Reboot {
    # Available to child step scripts. Call this only after the current step has
    # completed all work it needs to do before the reboot.
    New-Item -ItemType File -Path $RebootMarker -Force | Out-Null
    Write-Log 'Current step requested a reboot before continuing.'
}

function Reset-StepState {
    if (Test-Path -LiteralPath $StateDir) {
        Get-ChildItem -LiteralPath $StateDir -Filter '*.done' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    Remove-Item -LiteralPath $CompleteMarker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $RebootMarker -Force -ErrorAction SilentlyContinue
    Write-Log 'Customization state reset. Existing logs were preserved.'
}

if (-not (Test-Administrator)) {
    throw 'Run bootstrap.ps1 from an elevated Administrator PowerShell session. Unattend UserOnce should use an administrator account.'
}

New-Item -ItemType Directory -Force -Path $Root, $StateDir, $CacheDir, $LogDir | Out-Null

# Transcript captures output from the runner and child scripts in one place.
try {
    Start-Transcript -Path $LogFile -Append -Force | Out-Null
}
catch {
    # Logging should never prevent customization from running.
}

try {
    Write-Log "Starting customization with Windows PowerShell $($PSVersionTable.PSVersion)."
    Write-Log "Repository source: $RawBase"

    if ($ResetState) {
        Reset-StepState
    }

    # Persist the exact bootstrap version that began this run. Reboots resume the
    # same runner. Child step files are still downloaded fresh when their turn arrives.
    if ($PSCommandPath -and ((Resolve-Path -LiteralPath $PSCommandPath).Path -ne $LocalBootstrap)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $LocalBootstrap -Force
    }

    Disable-SetupAutoLogon
    Install-ResumeTask

    foreach ($step in $Steps) {
        $name = [string]$step.Name
        $relativePath = [string]$step.Path
        $doneMarker = Join-Path $StateDir "$name.done"
        $localStep = Join-Path $CacheDir "$name.ps1"
        $stepUrl = "$RawBase/$relativePath"

        if (Test-Path -LiteralPath $doneMarker) {
            Write-Log "Skipping completed step: $name"
            continue
        }

        Write-Log "Downloading step: $name"
        Invoke-Download -Uri $stepUrl -OutFile $localStep

        Write-Log "Running step: $name"
        & $localStep

        # A marker is written only after the step returned without throwing.
        New-Item -ItemType File -Path $doneMarker -Force | Out-Null
        Write-Log "Completed step: $name"

        if (Test-Path -LiteralPath $RebootMarker) {
            Remove-Item -LiteralPath $RebootMarker -Force

            if ($NoReboot) {
                Write-Log 'Reboot required. -NoReboot was specified, so stopping here. Reboot manually and run the bootstrap again.'
                exit 3010
            }

            Write-Log 'Rebooting. The startup task will resume at the next incomplete step.'
            Restart-Computer -Force
            exit 0
        }
    }

    New-Item -ItemType File -Path $CompleteMarker -Force | Out-Null
    Remove-ResumeTask
    Write-Log 'All customization steps completed successfully.'
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    Write-Log "The resume task and completed-step markers were left intact. Fix the problem and rerun bootstrap.ps1, or reboot to retry."
    throw
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
