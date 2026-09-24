<#
.SYNOPSIS
    Resumable Windows 11 post-install customization runner.

.DESCRIPTION
    Stable entry point for Windows 11 post-install customization.

    Designed for Windows PowerShell 5.1 included with Windows 11. It does not
    require PowerShell 7, winget, Git, OpenSSH, or any other package manager.

    Responsibilities:
      - require elevated execution
      - disable Setup autologon after the first bootstrap
      - persist itself under C:\ProgramData\proxmox-win11
      - register a SYSTEM startup task so provisioning resumes after reboots
      - download and execute ordered customization steps from GitHub
      - track completed steps with simple .done files
      - write a transcript log
      - reboot only when a successfully completed step requests it
      - remove the resume task after all steps finish

    Child step scripts should be small and idempotent. A step that requires a
    reboot should finish its work and then call Request-Reboot.
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

# Where step scripts live in the repository.
$StepsDir = 'windows/steps'

# Add customization steps here in the exact order they should run.
#
# Each entry is one script name without the .ps1 extension. It is also the
# name of the step's .done marker, so the script, the URL, and the marker can
# never disagree. Steps run in this list's order; the number prefix is only a
# readability aid, not the thing that orders them.
#
# A step is marked complete only after it exits without throwing an error.
# A script in windows/steps that is not listed here never runs.
$Steps = @(
    '010-remove-autologoncount'
    '020-openssh'
    '020-ssh-keys'    
    '030-update-winget'
    '030-winget-ready'
    '030-winget-configure'
    '040-git-config'
    '050-vscode-context-menu'
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
    # Setup may use Winlogon autologon to reach the first desktop. Once this
    # runner starts, reboot continuation is handled by a SYSTEM startup task.
    # Missing values are expected and are treated as a successful no-op.

    $key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

    if (-not (Test-Path -LiteralPath $key)) {
        throw "Winlogon registry key was not found: $key"
    }

    New-ItemProperty `
        -LiteralPath $key `
        -Name 'AutoAdminLogon' `
        -Value '0' `
        -PropertyType String `
        -Force | Out-Null

    foreach ($name in @('AutoLogonCount', 'DefaultPassword')) {
        $property = Get-ItemProperty `
            -LiteralPath $key `
            -Name $name `
            -ErrorAction SilentlyContinue

        if ($null -ne $property) {
            Remove-ItemProperty `
                -LiteralPath $key `
                -Name $name `
                -Force `
                -ErrorAction Stop
        }
    }

    Write-Log 'Disabled setup autologon and removed AutoLogonCount/DefaultPassword when present.'
}

function Install-ResumeTask {
    # Run as SYSTEM after every startup. No user logon is required to continue.
    # The 30-second delay gives networking and Windows services time to settle.

    $existingTask = Get-ScheduledTask `
        -TaskName $TaskName `
        -ErrorAction SilentlyContinue

    if ($null -ne $existingTask) {
        Write-Log "Startup resume task '$TaskName' already exists."
        return
    }

    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$LocalBootstrap`" -RepoOwner `"$RepoOwner`" -RepoName `"$RepoName`" -RepoRef `"$RepoRef`""

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $arguments

    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 6)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Write-Log "Installed startup resume task '$TaskName'."
}

function Remove-ResumeTask {
    $existingTask = Get-ScheduledTask `
        -TaskName $TaskName `
        -ErrorAction SilentlyContinue

    if ($null -ne $existingTask) {
        Unregister-ScheduledTask `
            -TaskName $TaskName `
            -Confirm:$false `
            -ErrorAction Stop

        Write-Log "Removed startup resume task '$TaskName'."
    }
    else {
        Write-Log "Startup resume task '$TaskName' was already absent."
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $attempts = 6

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $Uri `
                -OutFile $OutFile `
                -ErrorAction Stop

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
    # Child step scripts can call this function after they have completed all
    # pre-reboot work. The runner writes the step's .done marker first and then
    # performs the reboot, so the next startup continues at the following step.

    New-Item `
        -ItemType File `
        -Path $RebootMarker `
        -Force | Out-Null

    Write-Log 'Current step requested a reboot before continuing.'
}

function Reset-StepState {
    if (Test-Path -LiteralPath $StateDir) {
        Get-ChildItem `
            -LiteralPath $StateDir `
            -Filter '*.done' `
            -File `
            -ErrorAction SilentlyContinue |
            Remove-Item -Force
    }

    Remove-Item -LiteralPath $CompleteMarker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $RebootMarker -Force -ErrorAction SilentlyContinue

    Write-Log 'Customization state reset. Existing logs were preserved.'
}

if (-not (Test-Administrator)) {
    throw 'Run bootstrap.ps1 from an elevated Administrator PowerShell session.'
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $Root, $StateDir, $CacheDir, $LogDir | Out-Null

# Transcript captures both the runner and child-script output. Failure to start
# a transcript is intentionally non-fatal.
try {
    Start-Transcript -Path $LogFile -Append -Force | Out-Null
}
catch {
}

try {
    Write-Log "Starting customization with Windows PowerShell $($PSVersionTable.PSVersion)."
    Write-Log "Repository source: $RawBase"

    if ($ResetState) {
        Reset-StepState
    }

    # Keep a local copy so a reboot does not depend on GitHub just to start the
    # runner. Steps themselves are downloaded fresh immediately before execution.
    if ($PSCommandPath) {
        $currentPath = (Resolve-Path -LiteralPath $PSCommandPath).Path

        if ($currentPath -ne $LocalBootstrap) {
            Copy-Item `
                -LiteralPath $currentPath `
                -Destination $LocalBootstrap `
                -Force
        }
    }

    # Don't disable setup auto logon for now.
    # Disable-SetupAutoLogon

    Install-ResumeTask

    # A duplicated entry would silently skip on its second appearance, because
    # the .done marker from the first run already exists. Fail loudly instead.
    $duplicateSteps = $Steps | Group-Object | Where-Object { $_.Count -gt 1 }

    if ($null -ne $duplicateSteps) {
        $names = ($duplicateSteps | ForEach-Object { $_.Name }) -join ', '
        throw "The step list contains duplicate entries: $names"
    }

    foreach ($name in $Steps) {
        $doneMarker = Join-Path $StateDir "$name.done"
        $localStep = Join-Path $CacheDir "$name.ps1"
        $stepUrl = "$RawBase/$StepsDir/$name.ps1"

        if (Test-Path -LiteralPath $doneMarker) {
            Write-Log "Skipping completed step: $name"
            continue
        }

        Write-Log "Downloading step: $name"
        Invoke-Download -Uri $stepUrl -OutFile $localStep

        Write-Log "Running step: $name"
        & $localStep

        # A marker is written only after the child script returns successfully.
        New-Item `
            -ItemType File `
            -Path $doneMarker `
            -Force | Out-Null

        Write-Log "Completed step: $name"

        if (Test-Path -LiteralPath $RebootMarker) {
            Remove-Item -LiteralPath $RebootMarker -Force

            if ($NoReboot) {
                Write-Log 'Reboot required. -NoReboot was specified, so stopping here.'
                Write-Log 'Reboot manually; the SYSTEM startup task will resume automatically.'
                exit 3010
            }

            Write-Log 'Rebooting. The SYSTEM startup task will resume at the next incomplete step.'
            Restart-Computer -Force
            exit 0
        }
    }

    New-Item `
        -ItemType File `
        -Path $CompleteMarker `
        -Force | Out-Null

    Remove-ResumeTask
    Write-Log 'All customization steps completed successfully.'
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    Write-Log 'Completed-step markers were preserved. Fix the problem and rerun the bootstrap, or reboot to retry.'
    throw
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
