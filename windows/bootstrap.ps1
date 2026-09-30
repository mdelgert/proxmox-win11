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
    [string]$OnlyStep = '',
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
    # WinGet steps must run as the logged-on user, before any
    # step reboots and the runner resumes as SYSTEM.
    '010-base'
    '010-remove-autologoncount'
    '020-openssh'
    '020-network-private'
    '020-ssh-keys'
    '030-update-winget'
    '030-winget-ready'
    '030-winget-configure'
    '040-git-config'
    '050-vscode-context-menu'
    '999-complete'
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
    #
    # The task is re-registered on every run rather than left alone when it
    # already exists. An existing task can be disabled (debugging does exactly
    # that) or carry arguments from an older run, and either would mean no
    # resume after a reboot. Register-ScheduledTask -Force makes this the
    # simplest way to guarantee the task matches this run.

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

    Write-Log "Registered startup resume task '$TaskName'."
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

function Restore-UacPrompting {
    # The specialize pass set ConsentPromptBehaviorAdmin to 0 so that UserOnce
    # could elevate this runner without a consent dialog nobody was there to
    # answer. See windows/SpecializeUac.ps1.
    #
    # That is needed exactly once, for this first launch. Every later resume
    # comes from the SYSTEM startup task, which never needs UAC. So the default
    # of 5 goes back immediately, before any step runs - a failed or abandoned
    # run must not leave the machine with prompt-free elevation.
    #
    # Rerunning the bootstrap by hand after this point raises a normal UAC
    # prompt, which is correct: someone is sitting at the console.

    $key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    New-ItemProperty `
        -LiteralPath $key `
        -Name 'ConsentPromptBehaviorAdmin' `
        -Value 5 `
        -PropertyType DWord `
        -Force | Out-Null

    Write-Log 'Restored UAC consent prompting for administrators (ConsentPromptBehaviorAdmin = 5).'
}

function Update-ProcessPath {
    # A step can install a tool whose directory is added to the PATH stored in
    # the registry. This process inherited its environment when it started and
    # Windows never updates a running process, so later steps would not see it.
    # Rebuilding $env:Path from the registry after every step fixes that for
    # every step that follows, without a reboot.
    #
    # Entries this process added itself are preserved, and duplicates removed.

    $parts = @()

    foreach ($scope in 'Machine', 'User') {
        $value = [Environment]::GetEnvironmentVariable('Path', $scope)

        if ($value) {
            $parts += ( $value -split ';' | Where-Object { $_ } )
        }
    }

    $parts += ( $env:Path -split ';' | Where-Object { $_ } )

    $env:Path = ( ( $parts | Select-Object -Unique ) -join ';' )
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
            # A missing file is not a transport problem, so do not spend a
            # minute retrying it. This is what a typo in $Steps looks like.
            if ($_.Exception -is [System.Net.WebException]) {
                $httpResponse = $_.Exception.Response -as [System.Net.HttpWebResponse]

                if ($null -ne $httpResponse -and
                    $httpResponse.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                    throw "Not found (HTTP 404): $Uri"
                }
            }

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

# Only one runner at a time. A failed run leaves the resume task registered, so
# a reboot can start a SYSTEM run while someone is also running the bootstrap by
# hand. Two runners would write the same markers and interleave the transcript.
# 'Global\' scopes the mutex across sessions, which is what makes the SYSTEM
# case work. Windows releases an abandoned mutex when a process dies, so a hard
# failure cannot wedge this.
$RunMutex = New-Object System.Threading.Mutex($false, 'Global\ProxmoxWin11-Customize')

if (-not $RunMutex.WaitOne(0)) {
    Write-Log 'Another customization run is already in progress. Exiting.'
    exit 0
}

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

    if ($OnlyStep -and $ResetState) {
        throw 'Use -OnlyStep or -ResetState, not both.'
    }

    if ($ResetState) {
        Reset-StepState
    }

    # Debug aid for a single step, normally over SSH. The step runs in the
    # runner's own scope, so it still sees $RawBase, $Root, Invoke-Download,
    # Request-Reboot and Disable-SetupAutoLogon.
    #
    # This path deliberately leaves the resume task, UAC prompting,
    # complete.marker and every other step's marker alone, and it never
    # reboots the machine someone is debugging on.
    if ($OnlyStep) {
        if ($Steps -notcontains $OnlyStep) {
            Write-Log "Warning: '$OnlyStep' is not in the step list, so it does not run in a normal pipeline."
        }

        $doneMarker = Join-Path $StateDir "$OnlyStep.done"
        $localStep = Join-Path $CacheDir "$OnlyStep.ps1"
        $stepUrl = "$RawBase/$StepsDir/$OnlyStep.ps1"

        Write-Log "Single-step run: $OnlyStep. Any existing marker is ignored."
        Write-Log "Downloading step: $OnlyStep"
        Invoke-Download -Uri $stepUrl -OutFile $localStep

        Write-Log "Running step: $OnlyStep"
        & $localStep

        New-Item `
            -ItemType File `
            -Path $doneMarker `
            -Force | Out-Null

        Write-Log "Completed step: $OnlyStep"

        if (Test-Path -LiteralPath $RebootMarker) {
            Remove-Item -LiteralPath $RebootMarker -Force
            Write-Log 'The step requested a reboot. Suppressed for a single-step run.'
        }

        exit 0
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

    # Don't disable setup auto logon, move to complete task 999-complete.ps1
    # Disable-SetupAutoLogon

    Install-ResumeTask

    # Silent elevation is no longer required now that the resume task exists.
    Restore-UacPrompting

    # A duplicated entry would silently skip on its second appearance, because
    # the .done marker from the first run already exists. Fail loudly instead.
    $duplicateSteps = $Steps | Group-Object | Where-Object { $_.Count -gt 1 }

    if ($null -ne $duplicateSteps) {
        $names = ($duplicateSteps | ForEach-Object { $_.Name }) -join ', '
        throw "The step list contains duplicate entries: $names"
    }

    $rebootRequested = $false

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

        # Pick up PATH changes the step made, so the next step can use whatever
        # it just installed.
        Update-ProcessPath

        # A marker is written only after the child script returns successfully.
        New-Item `
            -ItemType File `
            -Path $doneMarker `
            -Force | Out-Null

        Write-Log "Completed step: $name"

        if (Test-Path -LiteralPath $RebootMarker) {
            Remove-Item -LiteralPath $RebootMarker -Force
            $rebootRequested = $true
            break
        }
    }

    # Finalize only once every step in the list has a marker.
    #
    # A reboot from a mid-list step leaves the resume task in place to carry on
    # after the restart. A reboot from the *final* step finalizes first, so the
    # machine does not come back only to run the whole pipeline again as SYSTEM
    # just to write a marker and delete a task.
    $remaining = @(
        $Steps | Where-Object {
            -not ( Test-Path -LiteralPath ( Join-Path $StateDir "$_.done" ) )
        }
    )

    if ($remaining.Count -eq 0) {
        New-Item `
            -ItemType File `
            -Path $CompleteMarker `
            -Force | Out-Null

        Remove-ResumeTask
        Write-Log 'All customization steps completed successfully.'
    }

    if ($rebootRequested) {
        if ($NoReboot) {
            Write-Log 'Reboot required. -NoReboot was specified, so stopping here.'
            Write-Log "Steps still incomplete: $($remaining.Count)."
            exit 3010
        }

        Write-Log "Rebooting. Steps still incomplete after restart: $($remaining.Count)."
        Restart-Computer -Force
        exit 0
    }
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

    try {
        $RunMutex.ReleaseMutex()
        $RunMutex.Dispose()
    }
    catch {
    }
}
