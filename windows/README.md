# Post-install bootstrap

Everything Windows does to itself *after* the unattended installation finishes.

`Autounattend.xml` references one URL, once. From then on the workflow lives in
this folder on GitHub, so changing what a new machine installs never means
rebuilding the ISO.

## The one hook

This is the only line in the answer file that points here, and it never has to
change (`assets/autounattend.xml`, `FirstLogonCommands`, `Order 2`):

```text
powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Bypass" -NoProfile -Command "Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1' -OutFile 'C:\Windows\Temp\bootstrap.ps1'; C:\Windows\Temp\bootstrap.ps1 -Install"
```

If you regenerate the answer file at
<https://schneegans.de/windows/unattend-generator/>, paste that command back in
under **Run custom scripts -> when the first user logs on (FirstLogon)**, and
redo the two answer-file edits described in [Autologon](#autologon).

## How a run works

```text
Windows Setup finishes
        │
        │  Autounattend.xml, FirstLogonCommands
        ▼
bootstrap.ps1 -Install
        │  copies itself to C:\ProgramData\Win11Setup\bin\bootstrap.ps1
        │  registers scheduled task  Win11Setup-Bootstrap  (at logon, highest privileges)
        │  arms autologon, starts the task, returns so OOBE can finish
        ▼
bootstrap.ps1            ◄──────────────────────────────┐
        │  re-downloads steps.json and steps\*.ps1      │
        │  runs the first step that is not complete     │
        │                                               │
        ├─ exit 0     mark complete, next step          │
        ├─ exit 3010  mark complete, reboot ────────────┤
        ├─ exit 3011  reboot and run the same step ─────┤  logon triggers
        └─ exit other stop and leave the step incomplete│  the scheduled task
        │                                               │
        ▼  no steps left                                │
disable autologon, remove the task, write COMPLETE ─────┘
```

Two properties matter and everything else follows from them:

- **State lives on disk, not in the script.** `state.json` records which steps
  finished, so a reboot is just an interruption.
- **The payload is fetched every run.** Edit a step, push, reboot the VM: the
  new version runs. `bootstrap.ps1` replaces its own local copy the same way.

## Files

In this repository:

```text
windows/
├── bootstrap.ps1          the master script; the only thing Autounattend references
├── steps.json             the ordered list of steps
├── steps/
│   ├── _lib.ps1           helpers the steps dot-source
│   ├── 10-baseline.ps1    power, sleep, long paths, ping
│   ├── 20-winget.ps1      make sure winget works
│   ├── 30-openssh.ps1     OpenSSH server
│   ├── 40-apps.ps1        winget packages, then a reboot
│   └── 50-windows-update.ps1   disabled by default
└── README.md
```

On the machine, everything is under `C:\ProgramData\Win11Setup`:

```text
C:\ProgramData\Win11Setup\
├── bin\bootstrap.ps1      the copy the scheduled task runs
├── steps\                 downloaded copies of the step scripts
├── steps.json             downloaded copy of the manifest
├── state.json             what has finished; delete it to start over
├── config.json            which base URL this machine bootstraps from
├── COMPLETE               written when the whole list finishes
└── logs\
    ├── bootstrap.log      every run, appended
    └── <step-id>.log      one log per step, appended per attempt
```

## The step contract

A step is an ordinary PowerShell script. The runner starts it in its own
`powershell.exe` process and looks only at the exit code:

| Exit code | Meaning |
| --- | --- |
| `0` | Finished. Move to the next step. |
| `3010` | Finished, but reboot first. The step is marked complete. |
| `3011` | Reboot and run this same step again. Used for Windows Update rounds. |
| anything else | Failed. The run stops and the step stays incomplete. |

`3010` is the value MSI uses for "reboot required", which is why it was picked.

Three environment variables are available to a step:

| Variable | Value |
| --- | --- |
| `WIN11SETUP_ROOT` | `C:\ProgramData\Win11Setup` |
| `WIN11SETUP_STEP` | the step id |
| `WIN11SETUP_ATTEMPT` | 1, 2 or 3 |

Rules worth keeping:

- **Make steps idempotent.** A step can run again after a failure or when you
  re-run the bootstrap by hand. Check before you install.
- **Let errors throw.** `_lib.ps1` sets `$ErrorActionPreference = 'Stop'`, and
  an unhandled error makes PowerShell exit 1, which the runner treats as a
  failure. You do not need your own try/catch.
- **Only ask for a reboot when something changed.** `40-apps.ps1` exits `3010`
  when it installed something and `0` when everything was already present.
- **Write output freely.** Anything a step prints lands in its own log.

### Adding a step

1. Add `windows/steps/60-my-thing.ps1`.
2. Add an entry to `windows/steps.json` (order in the array is run order):

   ```json
   { "id": "60-my-thing", "script": "steps/60-my-thing.ps1", "description": "..." }
   ```

3. Push. The next boot of any machine that has not finished picks it up.

Use `"enabled": false` to keep a step in the list without running it.

Numeric prefixes keep the order obvious. Ids are what state records, so
renaming a step makes an already-bootstrapped machine run it again.

## Testing on a machine that is already built

From an **elevated** PowerShell prompt:

```powershell
# Get the master script
irm https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1 -OutFile $env:TEMP\bootstrap.ps1

# Run one step, ignoring and not touching saved state - the fast edit loop
& $env:TEMP\bootstrap.ps1 -Only 30-openssh

# Show state, the scheduled task and the tail of the log
& $env:TEMP\bootstrap.ps1 -Status

# Start the whole list again from the first step
& $env:TEMP\bootstrap.ps1 -Reset
& $env:TEMP\bootstrap.ps1

# Install the resume task, as Autounattend does
& $env:TEMP\bootstrap.ps1 -Install

# Remove the task and turn autologon off
& $env:TEMP\bootstrap.ps1 -Uninstall
```

Point a test machine at a branch or a fork without touching the ISO:

```powershell
& $env:TEMP\bootstrap.ps1 -BaseUrl 'https://raw.githubusercontent.com/mdelgert/proxmox-win11/develop/windows'
```

The base URL is saved in `config.json`, so later runs stay on that branch until
you pass `-BaseUrl` again.

Every mode except `-Status` re-downloads the step scripts first, so the edit
loop is push, then `-Only`. To try a change without pushing it, edit the copy
in `C:\ProgramData\Win11Setup\steps\` and run that file directly:

```powershell
& C:\ProgramData\Win11Setup\steps\30-openssh.ps1
$LASTEXITCODE
```

## Debugging

```powershell
# What has finished, what failed, what is next
Get-Content C:\ProgramData\Win11Setup\state.json

# Follow the master log live
Get-Content C:\ProgramData\Win11Setup\logs\bootstrap.log -Wait -Tail 40

# One step's output
Get-Content C:\ProgramData\Win11Setup\logs\40-apps.log -Tail 60

# The resume mechanism
Get-ScheduledTask -TaskName Win11Setup-Bootstrap | Format-List TaskName, State
Start-ScheduledTask -TaskName Win11Setup-Bootstrap

# Autologon state
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' |
    Select-Object AutoAdminLogon, AutoLogonCount, DefaultUserName
```

`state.json` reads like this:

```json
{
  "status": "running",
  "completed": [ "10-baseline", "20-winget" ],
  "attempts": { "30-openssh": 1 },
  "rebootCount": 1,
  "lastStep": "30-openssh",
  "lastError": ""
}
```

To retry a single step, remove its id from `completed` and run the bootstrap
again. To start completely over, `-Reset`.

| Symptom | Cause |
| --- | --- |
| Nothing happened after install | Look at `logs\bootstrap.log`. If it is missing, the `FirstLogonCommands` line never ran; check `C:\Windows\Panther\UnattendGC\setupact.log`. |
| Reboots stop at the sign-in screen | Autologon could not be re-armed. See below. Sign in; the task resumes on its own. |
| A step edit had no effect | GitHub raw is behind a CDN. The downloader adds a random query string and no-cache headers, but a browser check may still show the old file for a few minutes. |
| The same step runs over and over | It exits `3011` unconditionally. Return `0` once the work is actually done. |
| `winget` is not recognised | A brand new profile sometimes needs a few minutes. `20-winget.ps1` waits and then falls back to installing App Installer directly. |
| Stopped after three tries | `MaxAttempts` is 3 per step. Fix the step, then `-Reset` or edit `state.json`. |
| Reboot loop | `MaxReboots` is 20 per bootstrap; the run refuses to reboot past that. |

## Autologon

Unattended reboot chains need the machine to log back in by itself, which means
autologon has to survive more than one logon. Two edits to `assets/autounattend.xml`
make that work, and both are already applied:

1. `<LogonCount>` is `10` instead of `1`.
2. The generator's `FirstLogon.ps1` no longer sets `AutoLogonCount` to `0`.
   `bootstrap.ps1` owns that lifecycle now.

During the run, `bootstrap.ps1` re-arms `AutoLogonCount` on every pass, so the
count never runs out no matter how many reboots the steps need. It does this
without ever handling a password: Windows keeps `DefaultPassword` in the
Winlogon key while autologon is active, and only the *count* is rewritten.

When the last step finishes, the bootstrap sets `AutoAdminLogon` to `0` and
deletes `AutoLogonCount` and `DefaultPassword`, so the finished machine has a
normal sign-in and no password sitting in the registry.

If `DefaultPassword` is already gone, the log says so and the run continues.
Reboots then stop at the sign-in screen, and the scheduled task resumes the
moment you sign in.

## Why a scheduled task instead of RunOnce

`RunOnce` deletes its own value before running, so every step would have to
re-register it, and a run that crashes at the wrong moment leaves a machine
that never resumes. A scheduled task is registered once, survives a crashed
run, and can be inspected and started by hand while testing. The bootstrap
removes it when the list is done.

## PowerShell version

Everything here targets **Windows PowerShell 5.1**, the version in the box on a
fresh Windows 11. Nothing in `bootstrap.ps1` or `_lib.ps1` needs PowerShell 7
or a module from the gallery, so the first run works before anything has been
installed or updated.

That means avoiding a few conveniences: no `??`, no ternary `? :`, no
`-Encoding utf8NoBOM`, and always `-UseBasicParsing` on `Invoke-WebRequest`,
because Windows 11 has no Internet Explorer engine for it to fall back to.

`40-apps.ps1` installs PowerShell 7 as `pwsh`, and a later step is free to
target it explicitly. The bootstrap itself stays on 5.1.

## Security

These scripts are fetched over HTTPS from a public repository and run as
administrator on a fresh machine, so treat this folder as trusted code:

- Never put passwords, keys or tokens in a step. Anything here is public.
- A fork or a branch changes what every machine built from that ISO installs.
- The hook URL pins the `main` branch, not a commit. Pin a tag or a commit SHA
  instead if you want a machine to keep installing exactly what it installed
  the day it was built.
