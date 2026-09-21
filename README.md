# proxmox-win11

Create a Windows 11 VM on Proxmox VE with a fully unattended installation.

The project is intentionally small and standalone. It borrows the user-experience ideas of Proxmox VE Helper Scripts—sensible defaults, an Advanced mode, dynamic storage selection, and one-command execution—without depending on the Community Scripts core libraries.

## Features

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

## Why two ISO modes?

### Single ISO

This is the recommended normal-use mode.

The script creates:

```text
windows11-autounattend.iso
```

That ISO contains both the Windows installer and `Autounattend.xml` at the root of the media. It also uses `efisys_noprompt.bin`, so the VM enters Windows Setup without a key press.

The VM only needs one CD/DVD device:

```text
ide0  Windows system disk
ide2  windows11-autounattend.iso
```

### Dual ISO

This mode is useful while developing or debugging `Autounattend.xml`.

The script creates:

```text
windows11-noprompt.iso
unattend.iso
```

The large Windows ISO normally remains unchanged. Each run quickly rebuilds the tiny `unattend.iso`, so you can edit `Autounattend.xml` and test again without rebuilding the entire Windows installer.

The VM uses:

```text
ide0  Windows system disk
ide1  unattend.iso
ide2  windows11-noprompt.iso
```

Both modes use the same `assets/Autounattend.xml` file as the source of truth.

## Repository layout

```text
proxmox-win11/
├── install.sh
├── README.md
├── LICENSE
├── .gitignore
├── assets/
│   └── README.md
└── lib/
    ├── common.sh
    ├── build-iso.sh
    └── create-vm.sh
```

After you add your answer file:

```text
assets/
├── README.md
└── Autounattend.xml
```

## Requirements

Run the project directly on a Proxmox VE host as `root`.

The script expects:

- Proxmox VE
- Internet access for the initial Windows ISO download
- At least one enabled Proxmox storage supporting `iso`
- At least one enabled Proxmox storage supporting `images`
- Enough free storage for the original Windows ISO plus the generated ISO

The script installs these packages automatically if they are missing:

- `wget`
- `xorriso`
- `whiptail`

Proxmox tools such as `qm`, `pvesm`, and `pvesh` are expected to already exist on the host.

## Create Autounattend.xml

This repository intentionally does not ship a Windows answer file because unattended files commonly contain personal settings, local account credentials, product keys, scripts, and other environment-specific information.

A very good way to create one is the Windows Unattend Generator by Christoph Schneegans:

https://schneegans.de/windows/unattend-generator/

Source code:

https://github.com/cschneegans/unattend-generator

Generate your file and save it as:

```text
assets/Autounattend.xml
```

The filename matters. Windows Setup expects the conventional `Autounattend.xml` name during automatic discovery.

### Security warning

Before committing `Autounattend.xml` to a public Git repository, inspect it carefully. It may contain:

- local account passwords
- product keys
- Wi-Fi credentials
- scripts or URLs
- organization-specific settings
- other secrets

For that reason, `assets/Autounattend.xml` is ignored by the included `.gitignore` by default.

If you intentionally want to publish the file, remove that ignore rule only after confirming the file contains nothing sensitive.

## Installation

### Option 1: Clone the repository

On the Proxmox host:

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

Run it:

```bash
./install.sh
```

### Option 2: One-line helper-style launcher

Once the repository is public, you can expose a Helper-Scripts-style command such as:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/install.sh)"
```

However, the current scaffold sources files from `lib/`, so a raw one-file invocation is **not yet the recommended launcher**. For the initial version, clone the repository and run `./install.sh`.

A later release can add a small bootstrap script that downloads the repository to a temporary directory and then executes `install.sh`. That preserves the clean multi-file project while still providing a one-line installation command.

## Running the helper

Start it from the repository directory:

```bash
./install.sh
```

The script first validates that:

- it is running as root
- `qm` and `pvesm` are available
- `assets/Autounattend.xml` exists

It then installs any missing dependencies.

### Storage selection

The helper queries Proxmox rather than assuming storage names.

ISO-capable storage is discovered using the equivalent of:

```bash
pvesm status --enabled 1 --content iso
```

VM disk storage is discovered using:

```bash
pvesm status --enabled 1 --content images
```

If there is only one eligible storage, it is selected automatically. If there are multiple choices, the helper displays a menu.

This means installations can use names such as:

```text
local
local-lvm
downloads
nvme
nfs
ceph
```

without hardcoding a particular home-lab layout.

The ISO builder does need a real filesystem path because `wget` and `xorriso` write ordinary files. It asks Proxmox to resolve the selected ISO volume using `pvesm path`, rather than constructing `/mnt/pve/...` manually.

## Default VM configuration

The current defaults are intentionally close to a simple Windows 11 VM that uses drivers already included with Windows:

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

The Windows disk currently uses IDE intentionally. That makes the initial installer work without adding VirtIO storage drivers to the installation media.

Similarly, E1000 is used so Windows Setup has a built-in network driver.

VirtIO storage/network support can be added later as an advanced feature once the basic unattended path is stable.

## Default versus Advanced settings

The helper follows the familiar Proxmox Helper Scripts pattern.

### Default

Accept the defaults and create the VM with minimal interaction.

### Advanced

Advanced mode lets you change:

- VM ID
- Proxmox VM name
- CPU core count
- RAM
- balloon minimum
- disk size
- network bridge
- whether the VM starts automatically

Storage and installation-media mode are selected before this step.

## Windows ISO source

The Microsoft ISO URL is defined once in:

```text
lib/common.sh
```

as `WINDOWS_URL`.

The source filename is automatically derived from the URL:

```bash
WINDOWS_SOURCE_NAME="${WINDOWS_URL##*/}"
```

Therefore, when Microsoft publishes a newer ISO, only `WINDOWS_URL` normally needs to change.

You can also override it for a single run without editing the repository:

```bash
WINDOWS_URL="https://example/path/new-windows.iso" ./install.sh
```

The project currently uses Microsoft's direct `software-static.download.prss.microsoft.com` URL for the Windows 11 25H2 consumer x64 ISO.

For the official public Windows download page, see:

https://www.microsoft.com/software-download/windows11

## How the no-prompt ISO works

Microsoft installation media contains an alternate UEFI boot image:

```text
efi/microsoft/boot/efisys_noprompt.bin
```

The standard boot image displays:

```text
Press any key to boot from CD or DVD...
```

The helper rebuilds the installation media with `xorriso` and selects `efisys_noprompt.bin` for UEFI boot.

No Windows ADK installation is required.

The rebuilt media keeps the normal BIOS El Torito boot image as well, although the generated Proxmox VM uses OVMF/UEFI.

## Boot order

The VM deliberately keeps its Windows disk before the installer:

Single ISO mode:

```text
ide0 -> ide2 -> net0
```

Dual ISO mode:

```text
ide0 -> ide2 -> net0 -> ide1
```

On the first boot, `ide0` is empty, so UEFI continues to the Windows installer on `ide2`.

After Windows has installed and rebooted, `ide0` is bootable and takes priority. This is important with a no-prompt installer because it prevents the VM from automatically re-entering Setup after every reboot.

## Generated files

Depending on the selected mode, the chosen Proxmox ISO storage can contain:

```text
<original Microsoft ISO>
windows11-autounattend.iso
windows11-noprompt.iso
unattend.iso
```

Not every generated file is required at the same time.

Single mode uses:

```text
<original Microsoft ISO>
windows11-autounattend.iso
```

Dual mode uses:

```text
<original Microsoft ISO>
windows11-noprompt.iso
unattend.iso
```

The original Microsoft ISO is preserved so a different customized ISO can be generated later without downloading Windows again.

## Rebuilding media after changing Autounattend.xml

### Dual mode

This is the fast development path.

Edit:

```text
assets/Autounattend.xml
```

Run the helper again and choose Dual ISO mode. The tiny `unattend.iso` is always regenerated from the current XML.

The much larger `windows11-noprompt.iso` is reused if it already exists.

### Single mode

`windows11-autounattend.iso` is reused when it already exists.

If you change `Autounattend.xml` and need to rebuild the single ISO, remove the generated ISO from the selected Proxmox ISO storage and rerun the helper.

A future improvement can store a checksum of `Autounattend.xml` and automatically rebuild the single ISO only when the XML changes.

## Development workflow

For initial development, use Dual ISO mode:

```text
edit Autounattend.xml
        ↓
run helper
        ↓
rebuild tiny unattend.iso
        ↓
create/test VM
```

Once the answer file is stable, use Single ISO mode for the clean normal workflow:

```text
Windows ISO + Autounattend.xml
        ↓
windows11-autounattend.iso
        ↓
create VM
        ↓
fully unattended Windows installation
```

## Project architecture

### `install.sh`

Small entry point. It loads the three library files and starts the workflow.

### `lib/common.sh`

Contains:

- defaults
- Windows ISO URL
- dependency installation
- Proxmox validation
- storage discovery
- menus and prompts
- main workflow orchestration

### `lib/build-iso.sh`

Contains Windows-media logic:

- downloads the Microsoft ISO
- rebuilds the no-prompt installer
- optionally embeds `Autounattend.xml`
- creates the small dual-mode `unattend.iso`

### `lib/create-vm.sh`

Contains only Proxmox VM creation logic:

- base VM
- OVMF
- EFI variables
- Secure Boot-compatible Microsoft certificate setting
- Windows disk
- TPM 2.0
- installation media
- boot order
- optional automatic start

Keeping these concerns separate makes the project easier to debug and prevents the main script from becoming a large monolithic shell file.

## Relationship to Proxmox VE Helper Scripts

This project is not part of or dependent on the Community Scripts project.

Their current architecture uses a shared core engine that provides common UI, VM, storage, validation, and error-handling functions. Application scripts source that engine rather than reimplementing all of those functions.

This repository intentionally starts standalone. That makes Windows-specific behavior easier to develop and debug without coupling the project to another repository's internal API.

Once the Windows workflow is stable, it could be adapted to their framework or submitted through their development/contribution process.

Useful references:

https://github.com/community-scripts/ProxmoxVE

https://github.com/community-scripts/core

## Troubleshooting

### `No enabled Proxmox storage supports content type 'iso'`

At least one Proxmox storage must allow ISO images.

In the Proxmox UI, inspect:

```text
Datacenter -> Storage -> <storage> -> Content
```

Ensure **ISO image** is allowed.

### `Could not resolve a filesystem path for ISO storage`

The builder needs ordinary filesystem access because it downloads and creates ISO files directly.

Use a file-backed ISO storage such as:

- Directory
- NFS
- CIFS/SMB

VM disks can still live on LVM-thin, ZFS, Ceph, or another image-capable backend.

### `Missing assets/Autounattend.xml`

Generate or copy your answer file into:

```text
assets/Autounattend.xml
```

### Windows Setup starts again after reboot

The helper intentionally places the Windows system disk first in the boot order. Check the VM configuration and make sure it has not been changed to put the installer ISO before `ide0`.

### Windows Setup does not detect the answer file

Check that the filename is exactly:

```text
Autounattend.xml
```

For Single ISO mode it should be at the root of the rebuilt Windows ISO.

For Dual ISO mode it should be at the root of `unattend.iso`.

### Need to test XML changes quickly

Use Dual ISO mode. It avoids rebuilding the large customized Windows ISO for every XML change.

## Current limitations

This is an initial scaffold, intentionally focused on getting the core unattended path reliable.

Not yet implemented:

- VirtIO storage/network driver injection
- automatic checksum-based rebuilds when `Autounattend.xml` changes
- Windows edition selection in the helper UI
- downloading a specific Autounattend.xml from a URL
- post-install guest-agent bootstrap validation
- templates / linked clones
- automated detection that Windows installation has completed
- one-file remote bootstrap installer
- CI shell linting

These are good follow-up features after the core installation flow has been tested on multiple Proxmox systems.

## Recommended first tests

Before publishing a `v1.0`, test at least these scenarios:

1. Fresh Proxmox host where `wget`, `xorriso`, or `whiptail` must be installed.
2. One ISO storage and one image storage.
3. Multiple ISO and VM storages so the selection menus appear.
4. Single ISO mode.
5. Dual ISO mode.
6. Existing Microsoft source ISO is reused.
7. Existing generated no-prompt ISO is reused.
8. VM is created with Default settings.
9. VM is created with Advanced settings.
10. Windows completes installation and reboots into `ide0` without re-entering Setup.
11. Edit `Autounattend.xml`, rerun Dual mode, and verify the new XML is used.

## License

MIT. See [LICENSE](LICENSE).
