# proxmox-win11

Create a Windows 11 VM on Proxmox VE with a fully unattended installation and a clean, resumable post-install customization pipeline.

The project is intentionally standalone. It borrows the useful user-experience ideas of Proxmox VE Helper Scripts—sensible defaults, an Advanced mode, dynamic storage selection, and small reusable components—without depending on the Community Scripts core libraries.

The design has two separate phases:

```text
Proxmox host                         Windows guest
────────────                         ─────────────
Build installation media      ->    Windows Setup
Create VM                           Autounattend.xml
Start VM                            first automatic logon
                                         |
                                         v
                                  windows/UserOnce.ps1
                                         |
                                         v
                                  windows/bootstrap.ps1
                                         |
                          +--------------+--------------+
                          |              |              |
                       step 010       step 020       step 030 ...
                          |
                       reboot?
                          |
                   resume as SYSTEM
```

The key principle is that `Autounattend.xml` should remain stable. It only bootstraps one public PowerShell script. Future customization changes live in GitHub instead of requiring another ISO rebuild.

---

## Features

### Proxmox / installation media

- Detects Proxmox ISO-capable and VM-image-capable storage dynamically.
- Does not hardcode `/mnt/pve/...` storage paths.
- Downloads the official Windows 11 ISO only when it is missing.
- Rebuilds the Windows ISO with Microsoft's `efisys_noprompt.bin`, removing the **Press any key to boot from CD/DVD** prompt for OVMF/UEFI VMs.
- Supports two unattended-install modes:
  - **Single ISO** — embeds `Autounattend.xml` into the Windows installer ISO.
  - **Dual ISO** — keeps the Windows installer separate and generates a tiny `unattend.iso` from the same XML file.
- Creates a Windows 11-compatible Proxmox VM with OVMF, Secure Boot-compatible EFI variables, TPM 2.0, Q35, CPU type `host`, and configurable resources.
- Can automatically start the VM when creation is complete.
- Reuses already-built Windows media instead of rebuilding it every run.

### Windows post-install customization

- `Autounattend.xml` only needs one small `UserOnce` bootstrap script.
- The real customization logic is downloaded from this GitHub repository.
- Uses Windows PowerShell 5.1 so it works immediately on a fresh Windows 11 install.
- Does not require PowerShell 7 for bootstrap or resume logic.
- Disables Windows Setup autologon once bootstrap has started.
- Removes `AutoLogonCount` and `DefaultPassword` when present.
- Creates a scheduled task that resumes customization as `SYSTEM` after reboot.
- Does not depend on a user automatically logging in again after reboot.
- Tracks completed steps with simple `.done` marker files.
- Downloads each step when it is needed.
- Supports deliberate reboot boundaries between steps.
- Writes a persistent transcript log.
- Can be launched manually on a test machine using the same master script.
- Removes its startup task when all steps are complete.

---

# Repository layout

```text
proxmox-win11/
├── install.sh
├── README.md
├── LICENSE
├── .gitignore
├── assets/
│   ├── README.md
│   └── Autounattend.xml          # you provide this; ignored by default
├── lib/
│   ├── common.sh
│   ├── build-iso.sh
│   └── create-vm.sh
└── windows/
    ├── UserOnce.ps1              # tiny script pasted into Unattend Generator
    ├── bootstrap.ps1             # master Windows customization runner
    └── steps/
        └── 010-base.ps1          # first example customization step
```

As customization grows, add numbered step files:

```text
windows/steps/
├── 010-base.ps1
├── 020-openssh.ps1
├── 030-winget.ps1
├── 040-git.ps1
└── 050-apps.ps1
```

Do **not** turn `bootstrap.ps1` into one giant customization script. Keep orchestration in the bootstrap and actual changes in small steps.

---

# Why two ISO modes?

## Single ISO

Recommended after the answer file is stable.

The helper creates:

```text
windows11-autounattend.iso
```

That ISO contains:

```text
Windows Setup
Autounattend.xml
no-prompt EFI boot image
```

The VM only needs:

```text
ide0  Windows system disk
ide2  windows11-autounattend.iso
```

### Advantages

- Cleanest finished VM configuration.
- One installation ISO.
- No separate unattended CD.

### Disadvantage

Changing `Autounattend.xml` requires rebuilding the large custom Windows ISO.

---

## Dual ISO

Recommended while developing `Autounattend.xml`.

The helper creates:

```text
windows11-noprompt.iso
unattend.iso
```

The VM uses:

```text
ide0  Windows system disk
ide1  unattend.iso
ide2  windows11-noprompt.iso
```

The large Windows ISO remains unchanged while the tiny `unattend.iso` is rebuilt every run.

### Development loop

```text
edit Autounattend.xml
        |
        v
rerun helper
        |
        v
rebuild tiny unattend.iso
        |
        v
test fresh VM
```

Both modes use the same `assets/Autounattend.xml` as the source of truth.

---

# Requirements

Run the Proxmox portion directly on a Proxmox VE host as `root`.

Requirements:

- Proxmox VE
- Internet access for the initial Windows ISO download
- At least one enabled Proxmox storage supporting `iso`
- At least one enabled Proxmox storage supporting `images`
- Enough free space for the source Windows ISO and generated ISO

The helper automatically installs these packages if missing:

- `wget`
- `xorriso`
- `whiptail`

Proxmox commands such as `qm`, `pvesm`, and `pvesh` are expected to already exist.

---

# 1. Create Autounattend.xml

This repository intentionally does not ship your Windows answer file by default because unattended files can contain credentials, product keys, personal settings, scripts, and other environment-specific information.

A convenient generator is Christoph Schneegans' Windows Unattend Generator:

https://schneegans.de/windows/unattend-generator/

Source:

https://github.com/cschneegans/unattend-generator

Save the generated file as:

```text
assets/Autounattend.xml
```

The filename matters.

## Security warning

Before committing `Autounattend.xml` to a public repository, inspect it carefully. It may contain:

- local account passwords
- product keys
- Wi-Fi credentials
- organization-specific values
- scripts
- URLs containing secrets or tokens

For that reason the included `.gitignore` ignores:

```text
assets/Autounattend.xml
```

Remove that rule only if you intentionally want to publish the file and have verified that it contains no secrets.

---

# 2. Configure UserOnce only once

The Unattend Generator supports scripts that run when a user logs on for the first time. The project uses that mechanism only as a **bootstrap**.

Do not put application installs, Windows features, Git setup, SSH setup, or update logic directly into `Autounattend.xml`.

Instead, paste the contents of:

```text
windows/UserOnce.ps1
```

into the generator's **UserOnce** script area.

The current bootstrap is intentionally small:

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$workRoot = Join-Path $env:ProgramData 'proxmox-win11'
$completeMarker = Join-Path $workRoot 'complete.marker'

if (Test-Path -LiteralPath $completeMarker) {
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$bootstrapUrl = 'https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1'
$bootstrapFile = Join-Path $env:TEMP 'proxmox-win11-bootstrap.ps1'

Invoke-WebRequest -UseBasicParsing -Uri $bootstrapUrl -OutFile $bootstrapFile
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrapFile
```

After this is embedded in `Autounattend.xml`, you normally do **not** need to change the answer file just because post-install customization changes.

New machines always download the current public `windows/bootstrap.ps1` when UserOnce runs.

---

# Why use Windows PowerShell 5.1?

A fresh Windows 11 installation includes **Windows PowerShell 5.1** as `powershell.exe`.

PowerShell 7 uses `pwsh.exe` and installs side-by-side; it does not replace Windows PowerShell 5.1.

For this project:

```text
bootstrap.ps1      -> Windows PowerShell 5.1 compatible
initial steps      -> Windows PowerShell 5.1 compatible
PowerShell 7       -> optional later customization step
```

This avoids a circular dependency where the automation system needs PowerShell 7 before it can install PowerShell 7.

Microsoft reference:

https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows

### PowerShell 5.1 compatibility rules

For bootstrap and early step scripts avoid newer PowerShell syntax such as:

- ternary operators
- `??`
- `ForEach-Object -Parallel`
- PowerShell 7-only modules

Prefer built-in Windows cmdlets and normal PowerShell 5.1 syntax.

---

# 3. How the master customization runner works

The master runner is:

```text
windows/bootstrap.ps1
```

Its job is orchestration, not customization.

On first execution it:

1. Requires Administrator/elevated execution.
2. Creates:

   ```text
   C:\ProgramData\proxmox-win11
   ```

3. Starts/continues logging.
4. Disables setup autologon.
5. Removes `AutoLogonCount` if present.
6. Removes `DefaultPassword` if present.
7. Copies the current bootstrap to the local working directory.
8. Creates a startup scheduled task running as `SYSTEM`.
9. Processes customization steps in order.
10. Writes a `.done` marker after each successful step.
11. Reboots if a completed step requests a reboot.
12. Resumes at the first incomplete step after boot.
13. Removes the scheduled task when everything finishes.
14. Creates `complete.marker`.

---

# Why use a SYSTEM startup task instead of repeated autologon?

The first automatic login is useful for reaching UserOnce, but it is a poor workflow engine.

The project deliberately switches away from autologon immediately.

After bootstrap starts:

```text
UserOnce
   |
   v
bootstrap.ps1
   |
   +--> disable AutoAdminLogon
   +--> remove AutoLogonCount
   +--> install startup task as SYSTEM
             |
             v
          reboot
             |
             v
      SYSTEM resumes runner
```

This means a software install or Windows feature can request a reboot without depending on the user automatically logging in again.

It also removes the need to guess how many `AutoLogon` counts will be needed.

The scheduled task is named:

```text
ProxmoxWin11-Customize
```

It runs 30 seconds after startup to give networking and normal services time to initialize.

---

# Runtime files on Windows

The runner uses:

```text
C:\ProgramData\proxmox-win11\
├── bootstrap.ps1
├── complete.marker
├── cache\
│   └── 010-base.ps1
├── logs\
│   └── customize.log
└── state\
    ├── 010-base.done
    └── reboot.requested
```

## Logs

Main log:

```text
C:\ProgramData\proxmox-win11\logs\customize.log
```

The bootstrap uses `Start-Transcript`, so output from both the runner and child PowerShell scripts is captured in one place.

For debugging, this should be the first file you inspect.

---

# 4. The step model

The bootstrap contains an ordered list:

```powershell
$Steps = @(
    @{ Name = '010-base'; Path = 'windows/steps/010-base.ps1' }
)
```

When you are ready to add another step:

```powershell
$Steps = @(
    @{ Name = '010-base';    Path = 'windows/steps/010-base.ps1' },
    @{ Name = '020-openssh'; Path = 'windows/steps/020-openssh.ps1' },
    @{ Name = '030-winget';  Path = 'windows/steps/030-winget.ps1' },
    @{ Name = '040-git';     Path = 'windows/steps/040-git.ps1' }
)
```

Each step is downloaded from GitHub only when it is its turn to run.

This is useful during development: you can fix a step in GitHub, remove its local `.done` marker, and rerun the master without rebuilding the Windows installer.

---

# Step design rules

Keep every step:

- small
- single-purpose
- PowerShell 5.1 compatible until you intentionally introduce PowerShell 7
- machine-wide when possible
- idempotent
- non-interactive
- explicit about failures

A good step should either:

```text
complete successfully
```

or:

```text
throw an error
```

Do not silently ignore a failed installer and then allow the master runner to create the `.done` marker.

## Example step skeleton

```powershell
$ErrorActionPreference = 'Stop'

Write-Host 'Installing Example...'

# Test whether the desired state already exists.
if (-not (Test-Path 'C:\Program Files\Example\example.exe')) {
    # perform installation
}

# Verify desired state.
if (-not (Test-Path 'C:\Program Files\Example\example.exe')) {
    throw 'Example installation failed.'
}

Write-Host 'Example is installed.'
```

That script is safe to retry.

---

# Requesting a reboot from a step

The bootstrap exposes this function to child steps:

```powershell
Request-Reboot
```

Use it only **after the current step is complete**.

Example:

```powershell
$ErrorActionPreference = 'Stop'

# Make configuration changes here.

# Verify the work completed successfully.

Request-Reboot
```

The runner then:

```text
marks current step done
        |
        v
reboots Windows
        |
        v
startup scheduled task runs as SYSTEM
        |
        v
first incomplete step starts
```

## Important

Do not request a reboot halfway through a step that still needs additional work after reboot.

Instead split the operation into two numbered steps:

```text
040-install-feature.ps1
050-configure-feature.ps1
```

Have step `040` complete its work, request a reboot, and let `050` perform post-reboot configuration.

This keeps resume logic simple and avoids building a state machine inside individual scripts.

---

# 5. Recommended order for early customization

Do not add everything at once.

Recommended development order:

```text
010-base.ps1
020-openssh.ps1
030-winget.ps1
040-git.ps1
050-apps.ps1
060-windows-update.ps1
```

Start with `010-base.ps1` only and prove that:

- UserOnce downloads the bootstrap
- the bootstrap creates its working directory
- `010-base` runs
- a `.done` marker appears
- logging works
- the scheduled task removes itself at completion

Then add one feature at a time.

### OpenSSH

OpenSSH Server is a good early test because it is a Windows capability and can be managed with built-in PowerShell/Windows tooling.

### WinGet

Treat WinGet separately. On fresh Windows installations, App Installer registration and execution context can be different from normal interactive user sessions. Do not make the core bootstrap depend on WinGet.

First make the runner reliable using built-in Windows functionality. Add WinGet only as an optional later step with explicit detection and verification.

### Git

Git also should not be required by the bootstrap. The bootstrap downloads raw files over HTTPS using `Invoke-WebRequest`, so it can run before Git exists.

This keeps the dependency chain clean:

```text
Windows PowerShell 5.1
        |
        v
bootstrap
        |
        v
optional software installs
```

---

# 6. Manual testing on a newly built Windows machine

The exact same master runner can be launched manually.

Open **Windows PowerShell as Administrator**.

Download the latest bootstrap:

```powershell
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = 'https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1'
$file = "$env:TEMP\proxmox-win11-bootstrap.ps1"
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $file
```

This uses the exact same code path as unattended installation.

That is important: avoid maintaining a special manual-test runner and a separate unattended runner.

---

# Testing without allowing an automatic reboot

During debugging you can run:

```powershell
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
    -File "$env:TEMP\proxmox-win11-bootstrap.ps1" `
    -NoReboot
```

If a step requests a reboot, the runner stops and leaves state intact instead of restarting immediately.

After manually rebooting, rerun the bootstrap.

---

# Reset all customization state

For a test VM where you intentionally want every step to run again:

```powershell
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
    -File 'C:\ProgramData\proxmox-win11\bootstrap.ps1' `
    -ResetState
```

This removes `.done` markers and `complete.marker` but preserves the log.

Use this only on test systems. An idempotent step should tolerate reruns, but not every third-party installer behaves perfectly when repeated.

---

# Rerun only one failed/development step

Suppose this marker exists:

```text
C:\ProgramData\proxmox-win11\state\030-winget.done
```

and you want to test that step again.

Delete only the marker:

```powershell
Remove-Item 'C:\ProgramData\proxmox-win11\state\030-winget.done'
```

Then rerun the bootstrap:

```powershell
& 'C:\ProgramData\proxmox-win11\bootstrap.ps1'
```

Earlier completed steps remain skipped.

If later steps depend on the changed step, remove their `.done` markers as well.

---

# Failure behavior

If a step throws an exception:

- that step does **not** receive a `.done` marker
- later steps do not run
- previous `.done` markers remain
- the log remains
- the scheduled resume task remains installed

Fix the problem in GitHub and then either:

```text
rerun bootstrap.ps1 manually
```

or reboot the VM and allow the startup task to retry.

The runner resumes from the first incomplete step.

---

# Why simple marker files instead of JSON state?

A JSON state database sounds attractive but creates more edge cases:

- partial writes
- schema/version changes
- corruption
- locking
- merge logic

For a linear provisioning process, files such as:

```text
010-base.done
020-openssh.done
030-winget.done
```

are easy to understand, inspect, delete, and recover manually.

Keep the state model boring until there is a real requirement for something more complex.

---

# Autologon cleanup

The bootstrap disables setup autologon with the Winlogon registry configuration after it has successfully started.

It sets:

```text
AutoAdminLogon = 0
```

and removes when present:

```text
AutoLogonCount
DefaultPassword
```

The reason is simple: after the bootstrap installs the startup task, autologon is no longer part of the resume mechanism.

Do not increase `LogonCount` merely to support reboot-heavy customization. The scheduled task solves that problem without leaving automatic interactive logon enabled.

---

# GitHub branch/ref behavior

By default the runner downloads steps from:

```text
https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/
```

The bootstrap supports:

```powershell
-RepoOwner
-RepoName
-RepoRef
```

For example, to test a development branch manually:

```powershell
& .\bootstrap.ps1 -RepoRef 'feature/openssh'
```

### Development

Using `main` is convenient because newly installed machines receive the current scripts.

### Production

Once the project becomes stable, consider using a release tag for repeatable provisioning.

For example:

```text
v1.0.0
```

A future improvement could introduce a small `channel` mechanism so `Autounattend.xml` can remain unchanged while the project controls whether `stable` points at a release tag or `main`.

---

# 7. Proxmox installation

Clone the repository on the Proxmox host:

```bash
git clone https://github.com/mdelgert/proxmox-win11.git
cd proxmox-win11
```

Add your answer file:

```bash
nano assets/Autounattend.xml
```

Make the entry script executable:

```bash
chmod +x install.sh
```

Run:

```bash
./install.sh
```

The helper validates:

- it is running as root
- Proxmox `qm` and `pvesm` exist
- `assets/Autounattend.xml` exists
- required packages are installed

---

# Storage selection

ISO-capable storage is discovered using the equivalent of:

```bash
pvesm status --enabled 1 --content iso
```

VM disk storage is discovered with:

```bash
pvesm status --enabled 1 --content images
```

If one storage is eligible, it is selected automatically. If multiple choices exist, the helper displays a menu.

The ISO builder needs filesystem access because `wget` and `xorriso` create ordinary files. It uses Proxmox storage resolution rather than hardcoding paths such as `/mnt/pve/downloads/...`.

---

# Default VM configuration

| Setting | Default |
| --- | --- |
| VM ID | Next available Proxmox VM ID |
| VM name | `win11` |
| CPU | `host` |
| CPU cores | `2` |
| Sockets | `1` |
| RAM | `16384 MB` |
| Balloon minimum | `2048 MB` |
| Disk | `300 GB` |
| Machine | `q35` |
| Firmware | OVMF / UEFI |
| TPM | TPM 2.0 |
| Network | E1000 |
| Bridge | `vmbr0` |
| OS type | `win11` |

The current Windows system disk uses IDE intentionally so the installer works without requiring VirtIO storage driver injection.

E1000 is also used initially because Windows includes the required network driver.

VirtIO can be introduced later after the unattended and post-install pipelines are stable.

---

# Default versus Advanced settings

## Default

Accept the defaults with minimal interaction.

## Advanced

Advanced mode currently lets you change:

- VM ID
- Proxmox VM name
- CPU core count
- RAM
- balloon minimum
- disk size
- network bridge
- whether the VM starts automatically

---

# Windows ISO source

The Microsoft ISO URL is defined once in:

```text
lib/common.sh
```

as:

```bash
WINDOWS_URL
```

The source filename is automatically derived:

```bash
WINDOWS_SOURCE_NAME="${WINDOWS_URL##*/}"
```

When Microsoft publishes a newer ISO, only the URL normally needs to change.

It can also be overridden for one run:

```bash
WINDOWS_URL="https://example/path/new-windows.iso" ./install.sh
```

Official Windows 11 download page:

https://www.microsoft.com/software-download/windows11

---

# How the no-prompt ISO works

Microsoft installation media contains:

```text
efi/microsoft/boot/efisys_noprompt.bin
```

The project rebuilds the ISO with `xorriso` and uses that UEFI boot image so the VM enters Setup without:

```text
Press any key to boot from CD or DVD...
```

No Windows ADK installation is required.

---

# Boot order

Single ISO:

```text
ide0 -> ide2 -> net0
```

Dual ISO:

```text
ide0 -> ide2 -> net0 -> ide1
```

On first boot, `ide0` is empty so UEFI continues to the Windows installer.

After installation, `ide0` is bootable and wins on subsequent boots. This is important because the installation ISO is intentionally configured to boot without waiting for a key press.

---

# Debugging blueprint

When something fails, debug one layer at a time.

## Layer 1: Did Windows Setup complete?

If no, debug:

```text
Autounattend.xml
Windows ISO
Proxmox boot/device configuration
```

Do not debug post-install scripts yet.

## Layer 2: Did UserOnce execute?

Check whether this exists:

```text
C:\ProgramData\proxmox-win11
```

If it does not exist, debug the UserOnce bootstrap.

The Unattend Generator also places/uses its own setup scripts under:

```text
C:\Windows\Setup\Scripts
```

and its UserOnce behavior can be debugged separately from this project.

## Layer 3: Did bootstrap run?

Inspect:

```text
C:\ProgramData\proxmox-win11\logs\customize.log
```

## Layer 4: Which step failed?

Inspect:

```text
C:\ProgramData\proxmox-win11\state
```

If you see:

```text
010-base.done
020-openssh.done
```

but no:

```text
030-winget.done
```

then `030-winget` is the first incomplete step.

## Layer 5: Reproduce manually

Download/run the master bootstrap from an elevated PowerShell console and watch the output interactively.

Avoid changing both the unattended answer file and the Windows customization runner at the same time. Change one layer, retest, and keep the other layer known-good.

---

# Recommended first tests

Before adding application installs, validate the orchestration itself:

1. Fresh Windows installation reaches UserOnce.
2. `C:\ProgramData\proxmox-win11` is created.
3. `010-base.ps1` downloads.
4. `010-base.done` appears.
5. `customize.log` contains the expected output.
6. `AutoAdminLogon` is disabled.
7. `AutoLogonCount` is removed when present.
8. The scheduled task exists while work is incomplete.
9. Add a temporary test step that calls `Request-Reboot`.
10. Verify Windows reboots without requiring another automatic user login.
11. Verify the startup task resumes at the next step.
12. Verify the task deletes itself after the final step.
13. Verify `complete.marker` exists.
14. Verify manually rerunning UserOnce does nothing after completion.

Only after these tests pass should you add OpenSSH, WinGet, Git, applications, and Windows Update automation.

---

# Current limitations / deliberate non-goals

The project intentionally does not yet attempt to solve everything.

Not yet implemented:

- VirtIO storage/network driver injection
- checksum-based Single ISO rebuilds when `Autounattend.xml` changes
- automatic Windows edition selection
- PowerShell 7 installation
- WinGet bootstrap/update logic
- Git installation
- OpenSSH installation
- Windows Update orchestration
- per-user customization after the machine-wide provisioning phase
- cryptographic verification of downloaded customization scripts
- a stable/release channel manifest
- a one-line multi-file Proxmox bootstrap launcher
- CI PowerShell linting/tests

These should be added incrementally after the core runner is proven reliable.

---

# Design rules to keep this project maintainable

1. **Autounattend.xml bootstraps; it does not provision applications.**
2. **bootstrap.ps1 orchestrates; it does not become a giant install script.**
3. **One logical feature per numbered step.**
4. **Every step must be retryable.**
5. **Mark a step complete only after verification succeeds.**
6. **Reboot only between completed steps.**
7. **Do not rely on repeated autologon.**
8. **Do not depend on WinGet, Git, or PowerShell 7 for the core runner.**
9. **Use logs and marker files instead of hidden state.**
10. **Add one feature at a time and test on a disposable VM.**

Following these rules prevents the provisioning flow from turning into the large fragile state machine that unattended Windows setups often become.

---

# Useful references

Windows Unattend Generator:

https://schneegans.de/windows/unattend-generator/

Unattend Generator source:

https://github.com/cschneegans/unattend-generator

Microsoft Windows unattended setup reference:

https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/

Microsoft PowerShell installation/version guidance:

https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows

Microsoft Scheduled Tasks / `schtasks`:

https://learn.microsoft.com/windows-server/administration/windows-commands/schtasks

Proxmox VE Helper Scripts:

https://github.com/community-scripts/ProxmoxVE

Community Scripts core:

https://github.com/community-scripts/core

---

# License

MIT. See [LICENSE](LICENSE).

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1';$f=\"$env:TEMP\proxmox-win11-bootstrap.ps1\";[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1';$f=\"$env:TEMP\proxmox-win11-bootstrap.ps1\";[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f -NoReboot"