#Requires -Version 5.1
<#
.SYNOPSIS
    Resumable post-install bootstrap for a freshly built Windows 11 machine.

.DESCRIPTION
    This is the single "master" script referenced once from Autounattend.xml.
    Everything it actually does lives in steps.json + steps\*.ps1 in the same
    GitHub folder, so the ISO never has to be rebuilt to change the workflow.

    It keeps state in C:\ProgramData\Win11Setup\state.json, so a step may
    reboot the machine and the run picks up at the next step afterwards.

    Written for Windows PowerShell 5.1, the version that ships with Windows 11.
    It must not depend on PowerShell 7 or on any module that is not in-box.

.PARAMETER Install
    Copy this script locally, register the resume scheduled task and start it.
    This is the mode Autounattend.xml uses.

.PARAMETER Only
    Run a single step by id and exit, ignoring and not updating saved state.
    Intended for testing one step by hand.

.PARAMETER Reset
    Delete saved state so the next run starts again at the first step.

.PARAMETER Status
    Print saved state and the tail of the log, then exit.

.PARAMETER Uninstall
    Remove the scheduled task and disable autologon. Leaves logs in place.

.EXAMPLE
    bootstrap.ps1 -Install

.EXAMPLE
    bootstrap.ps1                       # run/resume the step list now

.EXAMPLE
    bootstrap.ps1 -Only 30-openssh      # test one step
#>
[CmdletBinding()]
param(
    [string] $BaseUrl,
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Reset,
    [switch] $Status,
    [string] $Only,
    [switch] $NoSelfUpdate,
    [int]    $MaxAttempts = 3,
    [int]    $MaxReboots  = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

$DefaultBaseUrl = 'https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows'
$TaskName       = 'Win11Setup-Bootstrap'
$Root           = Join-Path $env:ProgramData 'Win11Setup'
$BinDir         = Join-Path $Root 'bin'
$StepDir        = Join-Path $Root 'steps'
$LogDir         = Join-Path $Root 'logs'
$StatePath      = Join-Path $Root 'state.json'
$ConfigPath     = Join-Path $Root 'config.json'
$ManifestPath   = Join-Path $Root 'steps.json'
$LocalCopy      = Join-Path $BinDir 'bootstrap.ps1'
$MainLog        = Join-Path $LogDir 'bootstrap.log'
$WinlogonKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

foreach ($dir in @($Root, $BinDir, $StepDir, $LogDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string] $Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    try { Add-Content -LiteralPath $MainLog -Value $line -Encoding UTF8 } catch { }
}

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'bootstrap.ps1 must run elevated. Start PowerShell with "Run as administrator".'
    }
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function ConvertTo-HashtableShallow {
    param($InputObject)
    $result = @{}
    if ($null -ne $InputObject) {
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = $property.Value
        }
    }
    return $result
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $OutFile,
        [int] $Retries = 5
    )
    # GitHub raw sits behind a CDN that caches for a few minutes. The random
    # query string plus the no-cache headers make an edit visible immediately.
    $bust    = '{0}?nocache={1}' -f $Url, [guid]::NewGuid().ToString('N')
    $headers = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }

    # Download beside the target and move it into place, so a failed transfer
    # never leaves a truncated file that a later run would treat as cached.
    $temp = "$OutFile.download"

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Invoke-WebRequest -Uri $bust -OutFile $temp -UseBasicParsing `
                -Headers $headers -TimeoutSec 60
            Move-Item -LiteralPath $temp -Destination $OutFile -Force
            return
        }
        catch {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            if ($attempt -eq $Retries) { throw }
            # Networking is often not ready yet on the first logon after setup.
            Write-Log ("Download failed ({0}/{1}): {2}" -f $attempt, $Retries, $_.Exception.Message) 'WARN'
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Save-Json {
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string] $Path)
    $json = $Object | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Config (remembers which repo/branch this machine was bootstrapped from)
# ---------------------------------------------------------------------------

function Get-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        return ConvertTo-HashtableShallow (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json)
    }
    return @{}
}

function Resolve-BaseUrl {
    $config = Get-Config
    if ($BaseUrl)          { $resolved = $BaseUrl }
    elseif ($config.baseUrl) { $resolved = $config.baseUrl }
    else                   { $resolved = $DefaultBaseUrl }

    $resolved = $resolved.TrimEnd('/')
    if ($config.baseUrl -ne $resolved) {
        $config.baseUrl = $resolved
        Save-Json -Object $config -Path $ConfigPath
    }
    return $resolved
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

function New-State {
    return @{
        status      = 'running'
        completed   = @()
        attempts    = @{}
        rebootCount = 0
        startedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        updatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        lastStep    = ''
        lastError   = ''
    }
}

function Get-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { return New-State }
    try {
        $state = ConvertTo-HashtableShallow (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
        $state.completed = @($state.completed | Where-Object { $_ })
        $state.attempts  = ConvertTo-HashtableShallow $state.attempts
        return $state
    }
    catch {
        Write-Log "state.json is unreadable ($($_.Exception.Message)); starting from the first step." 'WARN'
        return New-State
    }
}

function Save-State {
    param([Parameter(Mandatory)] $State)
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-Json -Object $State -Path $StatePath
}

# ---------------------------------------------------------------------------
# Autologon
#
# Windows decrements AutoLogonCount on every automatic logon and, when it hits
# zero, deletes AutoAdminLogon and DefaultPassword. Re-arming the count while
# DefaultPassword still exists keeps automatic logons available for as many
# reboots as the step list needs, without this script ever handling a password.
# ---------------------------------------------------------------------------

function Get-RegistryValue {
    param([string] $Key, [string] $Name)
    try { return (Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

function Enable-AutoLogonWindow {
    param([int] $Count = 5)
    if ([string]::IsNullOrEmpty((Get-RegistryValue $WinlogonKey 'DefaultPassword'))) {
        Write-Log ('Winlogon has no DefaultPassword, so autologon cannot be re-armed. ' +
                   'Reboots will stop at the sign-in screen; the resume task runs once you sign in.') 'WARN'
        return
    }
    Set-ItemProperty -LiteralPath $WinlogonKey -Name 'AutoAdminLogon' -Value '1' -Type String -Force
    Set-ItemProperty -LiteralPath $WinlogonKey -Name 'AutoLogonCount' -Value $Count -Type DWord -Force
    Write-Log ("Autologon armed for up to {0} more automatic logon(s)." -f $Count)
}

function Disable-AutoLogon {
    Set-ItemProperty -LiteralPath $WinlogonKey -Name 'AutoAdminLogon' -Value '0' -Type String -Force
    foreach ($name in @('AutoLogonCount', 'DefaultPassword')) {
        Remove-ItemProperty -LiteralPath $WinlogonKey -Name $name -Force -ErrorAction SilentlyContinue
    }
    Write-Log 'Autologon disabled and the stored password removed.'
}

# ---------------------------------------------------------------------------
# Resume mechanism (scheduled task, not RunOnce: it survives a crashed run and
# can be inspected and started by hand while testing)
# ---------------------------------------------------------------------------

function Register-ResumeTask {
    $account = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $LocalCopy)

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    # Give the shell and the network a moment before resuming.
    $trigger.Delay = 'PT30S'

    $principal = New-ScheduledTaskPrincipal -UserId $account -RunLevel Highest -LogonType Interactive

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    Write-Log ("Resume task '{0}' registered for {1}." -f $TaskName, $account)
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log ("Resume task '{0}' removed." -f $TaskName)
    }
}

# ---------------------------------------------------------------------------
# Self update: the copy on disk is refreshed from GitHub before the step loop
# runs, so an edit pushed to the repo takes effect on the very next boot.
# ---------------------------------------------------------------------------

function Update-Self {
    param([Parameter(Mandatory)][string] $Url)
    if ($NoSelfUpdate -or $PSCommandPath -ne $LocalCopy) { return }

    $candidate = Join-Path $BinDir 'bootstrap.new.ps1'
    try { Invoke-Download -Url "$Url/bootstrap.ps1" -OutFile $candidate }
    catch {
        Write-Log "Could not check for a newer bootstrap.ps1: $($_.Exception.Message)" 'WARN'
        return
    }

    $new = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
    $old = (Get-FileHash -LiteralPath $LocalCopy -Algorithm SHA256).Hash
    if ($new -eq $old) {
        Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log 'A newer bootstrap.ps1 is published; updating and restarting this run.' 'STEP'
    Move-Item -LiteralPath $candidate -Destination $LocalCopy -Force
    # -NoSelfUpdate on the child bounds this to exactly one restart.
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $LocalCopy -NoSelfUpdate
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------

function Sync-Payload {
    param([Parameter(Mandatory)][string] $Url)

    try { Invoke-Download -Url "$Url/steps.json" -OutFile $ManifestPath }
    catch {
        if (-not (Test-Path -LiteralPath $ManifestPath)) { throw }
        Write-Log "Could not refresh steps.json ($($_.Exception.Message)); using the cached copy." 'WARN'
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

    $wanted = @()
    if ($manifest.files) { $wanted += $manifest.files }
    foreach ($step in $manifest.steps) { $wanted += $step.script }

    foreach ($relative in ($wanted | Select-Object -Unique)) {
        $destination = Join-Path $Root ($relative -replace '/', '\')
        $parent      = Split-Path -LiteralPath $destination -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        try { Invoke-Download -Url "$Url/$relative" -OutFile $destination }
        catch {
            if (-not (Test-Path -LiteralPath $destination)) { throw }
            Write-Log "Could not refresh $relative; using the cached copy." 'WARN'
        }
    }

    Write-Log ("Payload synced from {0}" -f $Url)
    return $manifest
}

# ---------------------------------------------------------------------------
# Step execution
#
# Exit code contract:
#     0     success, move to the next step
#     3010  success, reboot, then move to the next step
#     3011  reboot and run this same step again (e.g. Windows Update rounds)
#     other failure, stop and leave the step incomplete
# ---------------------------------------------------------------------------

function Invoke-Step {
    param([Parameter(Mandatory)] $Step, [int] $Attempt)

    $path = Join-Path $Root ($Step.script -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) { throw "Step script not found: $path" }

    $log = Join-Path $LogDir ('{0}.log' -f $Step.id)
    Add-Content -LiteralPath $log -Encoding UTF8 -Value @"

===============================================================================
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($Step.id)  attempt $Attempt
===============================================================================
"@

    $env:WIN11SETUP_ROOT    = $Root
    $env:WIN11SETUP_STEP    = $Step.id
    $env:WIN11SETUP_ATTEMPT = $Attempt

    # Out-Host keeps the step's output off this function's output stream, so the
    # caller receives the exit code and nothing else.
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path 2>&1 |
        Tee-Object -FilePath $log -Append | Out-Host

    return $LASTEXITCODE
}

function Wait-ForShell {
    # Install mode starts the run from Autounattend's FirstLogonCommands, which
    # fire while Windows is still finishing the first logon. Waiting for
    # Explorer avoids the first step rebooting in the middle of that.
    param([int] $TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue) { return }
        Start-Sleep -Seconds 5
    }
    Write-Log 'Explorer did not appear within the timeout; continuing anyway.' 'WARN'
}

function Request-Reboot {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][string] $Reason)

    if ([int]$State.rebootCount -ge $MaxReboots) {
        throw "Reboot budget of $MaxReboots exhausted; refusing to reboot again."
    }
    $State.rebootCount = [int]$State.rebootCount + 1
    Save-State -State $State

    Write-Log ("Rebooting: {0}. Reboot {1} of {2}." -f $Reason, $State.rebootCount, $MaxReboots) 'STEP'
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit 0
}

function Complete-Run {
    param([Parameter(Mandatory)] $State)
    $State.status = 'complete'
    Save-State -State $State
    Disable-AutoLogon
    Unregister-ResumeTask
    Set-Content -LiteralPath (Join-Path $Root 'COMPLETE') -Encoding UTF8 `
        -Value ((Get-Date).ToString('o'))
    Write-Log 'All steps completed. Bootstrap finished.' 'STEP'
}

function Stop-Run {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][string] $Reason)
    $State.status    = 'failed'
    $State.lastError = $Reason
    Save-State -State $State
    Write-Log $Reason 'ERROR'
    Write-Log ("Bootstrap halted. Fix the step, then run: {0}" -f $LocalCopy) 'ERROR'
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

function Invoke-InstallMode {
    param([Parameter(Mandatory)][string] $Url)

    if ($PSCommandPath -and $PSCommandPath -ne $LocalCopy) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $LocalCopy -Force
    }
    elseif (-not (Test-Path -LiteralPath $LocalCopy)) {
        Invoke-Download -Url "$Url/bootstrap.ps1" -OutFile $LocalCopy
    }
    Write-Log ("Installed bootstrap to {0}" -f $LocalCopy)

    Register-ResumeTask
    Enable-AutoLogonWindow

    if (-not (Test-Path -LiteralPath $StatePath)) { Save-State -State (New-State) }

    # Start detached so Autounattend's FirstLogonCommands is not held open
    # while the steps run; the first reboot would otherwise land mid-OOBE.
    Start-ScheduledTask -TaskName $TaskName
    Write-Log 'Resume task started. Install mode done.'
}

function Invoke-StatusMode {
    if (Test-Path -LiteralPath $StatePath) {
        Write-Host "--- $StatePath ---"
        Get-Content -LiteralPath $StatePath -Raw | Write-Host
    }
    else { Write-Host 'No state file yet; the bootstrap has not run.' }

    Write-Host "`n--- scheduled task ---"
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { $task | Format-List TaskName, State | Out-String | Write-Host }
    else { Write-Host 'Not registered (normal once the bootstrap has finished).' }

    if (Test-Path -LiteralPath $MainLog) {
        Write-Host "--- last 25 log lines ---"
        Get-Content -LiteralPath $MainLog -Tail 25 | Write-Host
    }
}

function Invoke-RunMode {
    param([Parameter(Mandatory)][string] $Url)

    $state = Get-State
    if ($state.status -eq 'complete') {
        Write-Log 'Bootstrap already complete. Use -Reset to run the list again.'
        Unregister-ResumeTask
        return
    }

    $state.status = 'running'
    Save-State -State $state

    Wait-ForShell
    $manifest = Sync-Payload -Url $Url
    $steps    = @($manifest.steps | Where-Object { $_.enabled -ne $false })
    if ($steps.Count -eq 0) {
        throw 'steps.json contains no enabled steps; refusing to treat this run as complete.'
    }

    # Keep autologon alive while there is still work left to do.
    Enable-AutoLogonWindow
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Register-ResumeTask
    }

    foreach ($step in $steps) {
        if ($state.completed -contains $step.id) { continue }

        $attempt = [int]$state.attempts[$step.id] + 1
        if ($attempt -gt $MaxAttempts) {
            Disable-AutoLogon
            Stop-Run -State $state -Reason "Step '$($step.id)' failed $MaxAttempts times; giving up."
            return
        }

        $state.attempts[$step.id] = $attempt
        $state.lastStep           = $step.id
        Save-State -State $state

        Write-Log ("--> {0} (attempt {1}/{2}) {3}" -f $step.id, $attempt, $MaxAttempts, $step.description) 'STEP'
        $code = Invoke-Step -Step $step -Attempt $attempt
        Write-Log ("<-- {0} exit code {1}" -f $step.id, $code)

        switch ($code) {
            0 {
                $state.completed = @($state.completed) + $step.id
                Save-State -State $state
            }
            3010 {
                $state.completed = @($state.completed) + $step.id
                Save-State -State $state
                Request-Reboot -State $state -Reason "$($step.id) requested a reboot"
            }
            3011 {
                # Repeat: not marked complete, and this attempt does not count
                # against MaxAttempts because it was a deliberate re-run.
                $state.attempts[$step.id] = $attempt - 1
                Save-State -State $state
                Request-Reboot -State $state -Reason "$($step.id) asked to continue after a reboot"
            }
            default {
                Stop-Run -State $state -Reason "Step '$($step.id)' failed with exit code $code. See $LogDir\$($step.id).log"
                return
            }
        }
    }

    Complete-Run -State $state
}

function Invoke-OnlyMode {
    param([Parameter(Mandatory)][string] $Url, [Parameter(Mandatory)][string] $Id)

    $manifest = Sync-Payload -Url $Url
    $step     = $manifest.steps | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $step) {
        $ids = ($manifest.steps | ForEach-Object { $_.id }) -join ', '
        throw "No step with id '$Id'. Known ids: $ids"
    }

    Write-Log ("--> {0} (single step, state not updated)" -f $step.id) 'STEP'
    $code = Invoke-Step -Step $step -Attempt 1
    Write-Log ("<-- {0} exit code {1}" -f $step.id, $code)
    if ($code -eq 3010 -or $code -eq 3011) {
        Write-Log 'The step asked for a reboot. Reboot by hand when you are ready.' 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

$mutex    = New-Object System.Threading.Mutex($false, 'Global\Win11SetupBootstrap')
$hasMutex = $false
try {
    Assert-Administrator

    if ($Status) { Invoke-StatusMode; exit 0 }

    try { $hasMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] {
        # A previous run died without releasing it. We now own it.
        $hasMutex = $true
    }
    if (-not $hasMutex) {
        Write-Log 'Another bootstrap run is already in progress; exiting.' 'WARN'
        exit 0
    }

    Write-Log ('=== bootstrap.ps1 started as {0}\{1} on {2} (PowerShell {3}) ===' -f `
        $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $PSVersionTable.PSVersion)

    $url = Resolve-BaseUrl

    if ($Uninstall) {
        Unregister-ResumeTask
        Disable-AutoLogon
        Write-Log 'Uninstalled. Logs and state were left in place.'
        exit 0
    }

    if ($Reset) {
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $Root 'COMPLETE') -Force -ErrorAction SilentlyContinue
        Write-Log 'State cleared. The next run starts at the first step.'
        exit 0
    }

    if ($Install) { Invoke-InstallMode -Url $url; exit 0 }

    Update-Self -Url $url

    if ($Only) { Invoke-OnlyMode -Url $url -Id $Only }
    else       { Invoke-RunMode  -Url $url }

    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    exit 1
}
finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
