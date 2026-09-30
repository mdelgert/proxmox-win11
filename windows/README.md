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
    ├── SpecializeUac.ps1         # pasted into generator's System script slot
    ├── UserOnce.ps1              # tiny script pasted into Unattend Generator
    ├── bootstrap.ps1             # master Windows customization runner
    └── steps/
        ├── 010-base.ps1          # first example customization step
        ├── 020-openssh.ps1       # installs and enables OpenSSH Server
        └── 030-ssh-keys.ps1      # installs public SSH keys from GitHub
```

As customization grows, add numbered step files:

```text
windows/steps/
├── 010-base.ps1
├── 020-openssh.ps1
├── 030-ssh-keys.ps1
├── 040-winget.ps1
├── 050-git.ps1
└── 060-apps.ps1
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
Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$bootstrapFile`""
```

After this is embedded in `Autounattend.xml`, you normally do **not** need to change the answer file just because post-install customization changes.

New machines always download the current public `windows/bootstrap.ps1` when UserOnce runs.

---

# 3. Configure the System (specialize) script — required

UserOnce runs under the logged-on user's **non-elevated** token, even for a
member of Administrators, while `bootstrap.ps1` refuses to run unelevated. That
is why UserOnce launches it with `Start-Process -Verb RunAs`.

Under default UAC settings that RunAs raises a consent dialog on the secure
desktop. The first logon is unattended, so nobody clicks **Yes**: UserOnce
blocks on `-Wait` forever, and because `RunOnce` deletes its value *before*
running the command, nothing ever retries. The symptom is a VM that reaches the
desktop with no provisioning and no `C:\ProgramData\proxmox-win11` directory.

To avoid that, paste the contents of:

```text
windows/SpecializeUac.ps1
```

into the generator's **System** script area. It runs as SYSTEM during the
specialize pass and sets `ConsentPromptBehaviorAdmin = 0`, so administrators
elevate without a prompt. `EnableLUA` is left at `1` on purpose — turning UAC
off entirely breaks Appx/Store servicing that the WinGet steps depend on.

The weakened setting is only needed for **one** launch. Every later resume comes
from the SYSTEM startup task, which does not use UAC at all, so `bootstrap.ps1`
restores the Windows default (`5`) as soon as that task is registered — before
any customization step runs. A step that fails, or a run you abandon halfway,
cannot leave the VM with prompt-free elevation.

The practical exposure is therefore a few seconds during the first automatic
logon, on a machine with no network services published yet. Rerunning the
bootstrap by hand afterwards raises a normal consent prompt, which is what you
want when you are sitting at the console.

Both generator scripts are embedded in the answer file, so **regenerating
`Autounattend.xml` without pasting this one back in silently reintroduces the
hang.** In the current `assets/autounattend.xml` they appear as
`C:\Windows\Setup\Scripts\unattend-00.ps1` (this script, called from
`Specialize.ps1`) and `unattend-01.ps1` (UserOnce).

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

# 4. How the master customization runner works

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

# 5. The step model

The bootstrap contains an ordered list:

```powershell
$Steps = @(
    '010-base'
    '020-openssh'
    '030-ssh-keys'
)
```

Each entry is one script in `windows/steps` named `<entry>.ps1`. The same
string is the download URL, the local cache file name, and the `.done` marker
name, so they cannot drift apart.

Adding a step is a one-line append, with no punctuation to fix on the line
above:

```powershell
$Steps = @(
    '010-base'
    '020-openssh'
    '030-ssh-keys'
    '040-git'
)
```

Two rules follow from this shape:

- **The list decides the order, not the number prefix.** The prefixes are a
  readability aid so the files sort sensibly on disk. Duplicated numbers are
  untidy but harmless; the runner never looks at them.
- **A script in `windows/steps` that is not listed never runs.** Work in
  progress can sit in the directory safely until you add its line.

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

# 6. Recommended order for early customization

Do not add everything at once.

Recommended development order:

```text
010-base.ps1
020-openssh.ps1
030-ssh-keys.ps1
040-winget.ps1
050-git.ps1
060-apps.ps1
070-windows-update.ps1
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

This is implemented in `windows/steps/020-openssh.ps1`. The step:

- finds the versioned `OpenSSH.Server*` capability instead of hardcoding a version
- installs it with `Add-WindowsCapability` only when it is not already installed
- sets the `sshd` service to `Automatic` and starts it
- creates or enables the `OpenSSH-Server-In-TCP` inbound firewall rule on TCP 22
- sets the machine-wide OpenSSH `DefaultShell` to Windows PowerShell
- verifies the service is running and `Automatic` before returning

No reboot is required. The capability is downloaded from Windows Update as a
Feature on Demand, so the VM needs internet access (or a configured local
capability source) when this step runs.

After it completes you can connect with the local account created by
`Autounattend.xml`:

```bash
ssh <user>@<vm-ip>
```

### SSH keys

`windows/steps/030-ssh-keys.ps1` installs the public keys published at:

```text
https://github.com/mdelgert.keys
```

GitHub exposes only public keys at that URL, so nothing secret is downloaded.

Change the account by editing `$GitHubUser` at the top of the step.

Keys are written to:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

That file — not the usual `~/.ssh/authorized_keys` — is the correct location
because the default Windows `sshd_config` ends with:

```text
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

For any account in the Administrators group, that directive replaces the
per-user file, so a key placed in the user profile is ignored. The account
created by `Autounattend.xml` is an administrator, so the machine-wide file is
what matters. A standard (non-administrator) account would instead need
`C:\Users\<user>\.ssh\authorized_keys`, which this step does not manage.

The step:

- rejects any downloaded line that is not a recognized SSH public key, so an
  error page or captive-portal response is never written into the key file
- preserves keys that are already present and never appends a duplicate
- writes ASCII with LF endings, because `sshd` rejects a UTF-8 BOM
- restricts the file to `Administrators` and `SYSTEM` with `icacls` using
  well-known SIDs, since `sshd` ignores a file that others can write
- verifies every downloaded key is present in the file before returning

No reboot or service restart is needed; `sshd` reads authorized key files on
every incoming connection.

Password authentication is left enabled. Disabling it is a separate decision
and belongs in its own step, after you have confirmed key login works.

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

# 7. Manual testing on a newly built Windows machine

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

# 8. Proxmox installation

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

If it does not exist, debug the UserOnce bootstrap. Its log is written to the
first user's temp directory:

```text
C:\Users\<user>\AppData\Local\Temp\UserOnce.log
```

A log that stops at the `unattend-01.ps1` step usually means the elevation
prompt was never answered: `Start-Process -Verb RunAs` blocks on an unattended
desktop unless `ConsentPromptBehaviorAdmin` is 0. Verify that the System
(specialize) script from `windows/SpecializeUac.ps1` is actually present in the
answer file, and check the value on the VM:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name ConsentPromptBehaviorAdmin
```

Because `RunOnce` deletes its value before running the command, a blocked or
failed UserOnce never retries by itself. Rerun the bootstrap by hand from an
elevated PowerShell session.

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
- per-user `authorized_keys` for non-administrator accounts
- hardening `sshd_config` (for example disabling password authentication)
- Windows Update orchestration
- per-user customization after the machine-wide provisioning phase
- cryptographic verification of downloaded customization scripts
- a stable/release channel manifest
- a one-line multi-file Proxmox bootstrap launcher
- CI PowerShell linting/tests

These should be added incrementally after the core runner is proven reliable.

---

# Recommended next revisions

None of these are blocking. They are ordered by how much trouble they save.

## Operational notes worth knowing now

- **A WinGet step can never be fixed by the resume task.** winget is not
  supported in a SYSTEM context, and the resume task runs as SYSTEM. If
  `030-update-winget`, `030-winget-ready` or `030-winget-configure` fails, a
  reboot retry will fail identically. Recover with a manual elevated run in a
  user session (the copy/paste one-liners do this).
- **A mid-pipeline reboot pushes every later step into SYSTEM context.** Steps
  that write to a user profile or read a user-scope install break there.
  `040-git-config` (`git config --global`) and `050-vscode-context-menu` (VS
  Code installs per-user by default) are both in that category, which is why
  the only `Request-Reboot` lives in `999-complete`.

## Runner

1. **Move the step list out of `bootstrap.ps1`.** Every step-list change
   currently edits the 470-line orchestrator. Comparable tools all keep the
   ordered work in data with the engine separate (Packer templates, Ansible
   playbooks, cloud-init user-data, MDT task sequences), and it is design rule
   #1 applied one level down: the runner orchestrates, it is not the
   configuration.

   Shape, whichever format is chosen: `windows/steps.<ext>` fetched and cached
   like `bootstrap.ps1` itself, a `-StepsFile` override for testing a different
   order without pushing, validation on load (non-empty, no duplicates, names
   matching `^[A-Za-z0-9._-]+$`), and a loud failure when the manifest is
   missing or empty rather than a silent zero-step run. About 25 lines, once.

   Two bonuses: the resume task runs the *cached* bootstrap, so today its step
   list is frozen at first-run time while steps download fresh — a separately
   fetched manifest makes a resumed run consistent. And machine profiles become
   free (`steps.txt`, `steps-minimal.txt`).

   **Format choice.** JSON has no comment syntax, and `ConvertFrom-Json` on
   PowerShell 5.1 rejects `//`, `/* */`, `#` and trailing commas (tested on
   5.1.26100.6584). Comments as *fields* do work, so both of these are viable:

   ```text
   # steps.txt - least to type, cannot fail to parse,
   # comments sit exactly where they apply
   010-base

   # WinGet steps must run as the logged-on user, before any
   # step reboots and the runner resumes as SYSTEM.
   030-update-winget
   030-winget-ready
   ```

   ```json
   {
     "steps": [
       { "name": "010-base" },
       { "name": "030-update-winget",
         "note": "must run as the logged-on user, before any reboot" }
     ]
   }
   ```

   Per-step JSON objects keep each note attached to its step and are
   extensible — a `note` could even be logged as the step runs — at the cost of
   more punctuation by hand and the temptation to add per-step flags that
   belong inside the steps themselves. A flat `"steps": ["010-base"]` array
   with one `_notes` block is the shape to avoid: it separates every comment
   from the line it describes.

2. **Rotate `customize.log`.** `Start-Transcript -Append` grows it forever.
   Fine on a VM you rebuild, annoying on one you keep.
3. **Clean the cache after a successful install.** `030-update-winget` leaves
   about 394 MB (App Installer bundle plus dependency archive) in
   `C:\ProgramData\proxmox-win11\cache` permanently.
4. **Move the duplicate-step check ahead of the side effects.** It validates
   static configuration but currently runs after `Install-ResumeTask` and
   `Restore-UacPrompting`.
5. **Share one `Invoke-Step` between `-OnlyStep` and the main loop.** The
   download/run/marker logic is duplicated, which was deliberate at the time,
   and the two have already drifted once (`Update-ProcessPath` went into the
   loop only).
6. **Pin `-RepoRef` to a tag for a build you want to reproduce.** Steps are
   downloaded at run time, so a push mid-provision changes what a resumed run
   executes.

## Steps and configuration

7. **Make `999-complete` self-contained.** It calls `Disable-SetupAutoLogon`
   and `Request-Reboot`, both defined by the runner, so it cannot be run
   standalone at all; and it hardcodes `C:\ProgramData\proxmox-win11` instead
   of using the runner's `$Root`.
8. **Set `scope: machine` for VS Code in `baseline.dsc.winget`** if you ever
   want `050-vscode-context-menu` to work outside the installing user's
   session. It currently lands in `%LOCALAPPDATA%`.
9. **Delete `windows/steps/misc/`.** Seven unreferenced scripts in a repo whose
   whole premise is that the `$Steps` list is the truth.
10. **Fix the remaining README drift.** Earlier sections still name steps that
   do not exist (`030-ssh-keys`, `040-winget`, `060-apps`,
   `040-install-feature`, `050-configure-feature`, `070-windows-update`).

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
# Troubleshooting and testing the scripts

Every command below needs an **elevated** PowerShell session — `bootstrap.ps1`
throws `Run bootstrap.ps1 from an elevated Administrator PowerShell session.`
otherwise.

Runner state lives under `C:\ProgramData\proxmox-win11`:

```text
state\<step>.done       one marker per completed step
cache\<step>.ps1        last downloaded copy of each step
logs\customize.log      transcript of every run
bootstrap.ps1           local copy used by the resume task
complete.marker         written after the final step succeeds
```

## Copy/paste one-liners

Self-contained: each downloads what it needs and runs it. Paste into an
**elevated** PowerShell (or `cmd`) on the VM. No prior setup required.

Run every step that has not completed yet:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1';$f=Join-Path $env:TEMP 'bootstrap.ps1';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f"
```

Run every step from scratch (clears all `.done` markers, keeps logs):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1';$f=Join-Path $env:TEMP 'bootstrap.ps1';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f -ResetState"
```

Same, but stop at a reboot request instead of restarting (exit code `3010`):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1';$f=Join-Path $env:TEMP 'bootstrap.ps1';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f -ResetState -NoReboot"
```

Run the steps from a branch instead of `main` (edit both the URL and `-RepoRef`):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$b='my-branch';$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/'+$b+'/windows/bootstrap.ps1';$f=Join-Path $env:TEMP 'bootstrap.ps1';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f -RepoRef $b"
```

Run exactly ONE step through the runner (the recommended way to debug a step —
it gets `$RawBase`, `$Root`, `Invoke-Download`, `Request-Reboot` and
`Disable-SetupAutoLogon`, ignores any existing `.done` marker, and never reboots):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s='030-winget-configure';$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/bootstrap.ps1';$f=Join-Path $env:TEMP 'bootstrap.ps1';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f -OnlyStep $s"
```

Download and run one step straight from GitHub (see the standalone limits below):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$n='020-network-private';$u='https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/windows/steps/'+$n+'.ps1';$f=Join-Path $env:TEMP ($n+'.ps1');[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f;& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $f"
```

Rerun the copy the last bootstrap already cached (no download):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\proxmox-win11\cache\020-network-private.ps1"
```

---

The sections below break the same operations out, for when you want to combine
them or inspect state. They assume these two variables:

```powershell
$repo = 'https://raw.githubusercontent.com/mdelgert/proxmox-win11/main'
$boot = Join-Path $env:TEMP 'bootstrap.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri "$repo/windows/bootstrap.ps1" -OutFile $boot
```

## Run everything that has not completed yet

Steps with a `.done` marker are skipped, so this is safe to repeat after fixing
a failure.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $boot
```

## Run everything from scratch

`-ResetState` deletes every `.done` marker plus `complete.marker`. Logs are kept.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $boot -ResetState
```

Add `-NoReboot` to stop at a reboot request instead of restarting. The run exits
with code `3010` and the resume task continues at the next boot.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $boot -ResetState -NoReboot
```

## Re-run ONE step

Use `-OnlyStep`. The step runs *inside* the runner, so it gets the variables and
functions it expects, and nothing else is touched:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $boot -OnlyStep '030-winget-configure'
```

`-OnlyStep` ignores any existing `.done` marker, writes that marker when the
step succeeds (so a normal run continues past it), and leaves the resume task,
UAC prompting, `complete.marker` and every other marker alone. A
`Request-Reboot` from the step is reported and suppressed, so it will not
restart a machine you are debugging on. It cannot be combined with
`-ResetState`.

A step not listed in `$Steps` still runs, with a warning — useful for a script
you have not wired up yet.

The older approach still works if you want the step to run as part of a full
pass: delete its marker and run the bootstrap normally.

```powershell
Remove-Item 'C:\ProgramData\proxmox-win11\state\040-git-config.done'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $boot
```

## Test a step you are still editing

Push to a branch and point the runner at it. `-RepoRef` controls where steps are
downloaded from and is carried into the resume task.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $boot -RepoRef 'my-branch'
```

A script in `windows/steps` that is not listed in `$Steps` inside
`bootstrap.ps1` never runs, no matter what is in the repository.

## Running a single step file on its own

Fine for a quick check, but **these steps fail when run standalone**, because
they use variables and functions that `bootstrap.ps1` defines:

| Step | Needs from the runner |
| --- | --- |
| `030-winget-configure` | `$RawBase`, `$Root`, `Invoke-Download` |
| `030-winget-baseline` | `$RawBase`, `$Root`, `Invoke-Download` |
| `999-complete` | `Disable-SetupAutoLogon`, `Request-Reboot` |

Use `-OnlyStep` for those three. Any other step runs on its own — download a
fresh copy:

```powershell
$name = '020-network-private'
$step = Join-Path $env:TEMP "$name.ps1"
Invoke-WebRequest -UseBasicParsing -Uri "$repo/windows/steps/$name.ps1" -OutFile $step
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $step
```

Or rerun the copy the last bootstrap already cached:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\proxmox-win11\cache\020-network-private.ps1'
```

Note that running a step this way does **not** write a `.done` marker, so the
next bootstrap run will execute it again.

## Read the log

```powershell
Get-Content 'C:\ProgramData\proxmox-win11\logs\customize.log' -Tail 60
Select-String -Path 'C:\ProgramData\proxmox-win11\logs\customize.log' -Pattern 'FAILED'
```

## Inspect progress and the resume task

```powershell
Get-ChildItem 'C:\ProgramData\proxmox-win11\state'
Get-ScheduledTask -TaskName 'ProxmoxWin11-Customize'
Get-ScheduledTaskInfo -TaskName 'ProxmoxWin11-Customize'
```

The task is registered on the first bootstrap run and removed automatically
after the last step completes.

### The resume task while you debug

If a step failed, the task is still registered, so a reboot starts a **SYSTEM**
run 30 seconds into the next boot. Two runners can no longer trample each other
— `bootstrap.ps1` holds a global mutex and a second run exits immediately with
`Another customization run is already in progress.` — but a SYSTEM run still
cannot succeed at the WinGet steps, so it will just fail again and add noise.

To stop a reboot kicking one off at all:

```powershell
Disable-ScheduledTask -TaskName 'ProxmoxWin11-Customize'
# ... debug, then
Enable-ScheduledTask -TaskName 'ProxmoxWin11-Customize'
```

Note that the next normal `bootstrap.ps1` run **re-registers** the task, which
also re-enables it. That is deliberate: a disabled or stale task silently means
no resume after a reboot, which is worse than an extra registration.
