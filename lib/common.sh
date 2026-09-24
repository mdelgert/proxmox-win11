#!/usr/bin/env bash

# Shared configuration and helper functions.

PROJECT_NAME="Proxmox Windows 11"
DEFAULT_VM_NAME="vm-win11"
DEFAULT_CORES=2
DEFAULT_MEMORY=16384
DEFAULT_BALLOON=2048
DEFAULT_DISK_SIZE=300
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MODE="single"

# Update this URL when Microsoft publishes a newer Windows 11 ISO.
WINDOWS_URL="${WINDOWS_URL:-https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso}"
WINDOWS_SOURCE_NAME="${WINDOWS_URL##*/}"
WINDOWS_SINGLE_NAME="windows11-autounattend.iso"
WINDOWS_NOPROMPT_NAME="windows11-noprompt.iso"
UNATTEND_ISO_NAME="unattend.iso"
# Lowercase on disk, matching the unattend-generator export. This path is on a
# case-sensitive filesystem, so the spelling has to be exact. build-iso.sh
# writes the file to the ISO root as Autounattend.xml, where Windows Setup
# looks it up case-insensitively.
AUTOUNATTEND_XML="${AUTOUNATTEND_XML:-$ROOT_DIR/assets/autounattend.xml}"

msg()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root on a Proxmox VE node."
}

require_proxmox() {
  command -v qm >/dev/null 2>&1 || die "qm was not found. Run this on a Proxmox VE host."
  command -v pvesm >/dev/null 2>&1 || die "pvesm was not found. Run this on a Proxmox VE host."
}

install_dependencies() {
  local missing=() cmd pkg
  for cmd in wget xorriso whiptail; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) && return 0

  msg "Installing required packages: ${missing[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

next_vmid() {
  pvesh get /cluster/nextid 2>/dev/null || echo 100
}

storage_list() {
  local content="$1"
  pvesm status --enabled 1 --content "$content" 2>/dev/null | awk 'NR>1 {print $1}'
}

choose_storage() {
  local content="$1" title="$2"
  local storages=() s menu=()
  mapfile -t storages < <(storage_list "$content")
  ((${#storages[@]} > 0)) || die "No enabled Proxmox storage supports content type '$content'."

  if ((${#storages[@]} == 1)); then
    printf '%s\n' "${storages[0]}"
    return 0
  fi

  for s in "${storages[@]}"; do
    menu+=("$s" "$(pvesm status --storage "$s" 2>/dev/null | awk 'NR==2 {print $2 ", free " $6 " KiB"}')")
  done

  whiptail --backtitle "$PROJECT_NAME" --title "$title" --menu \
    "Select storage:" 18 72 10 "${menu[@]}" 3>&1 1>&2 2>&3
}

storage_path() {
  local storage="$1" filename="$2"
  pvesm path "${storage}:iso/${filename}" 2>/dev/null || \
    die "Could not resolve a filesystem path for ISO storage '$storage'. Use a file-based ISO storage (dir/NFS/CIFS) that supports ISO content."
}

prompt_input() {
  local title="$1" prompt="$2" default="$3"
  whiptail --backtitle "$PROJECT_NAME" --title "$title" --inputbox "$prompt" 10 68 "$default" 3>&1 1>&2 2>&3
}

prompt_yesno() {
  local title="$1" prompt="$2"
  whiptail --backtitle "$PROJECT_NAME" --title "$title" --yesno "$prompt" 10 68
}

validate_autounattend() {
  [[ -s "$AUTOUNATTEND_XML" ]] || die "Missing $AUTOUNATTEND_XML. Add your generated Autounattend.xml there first."
}

select_mode() {
  whiptail --backtitle "$PROJECT_NAME" --title "INSTALL MEDIA MODE" --menu \
    "Choose how unattended setup is provided.\n\nSingle ISO is cleanest for normal use.\nDual ISO is faster while debugging Autounattend.xml." \
    16 76 2 \
    single "Embed Autounattend.xml into the Windows ISO" \
    dual   "Windows ISO + small separate unattend.iso" \
    3>&1 1>&2 2>&3
}

main_menu() {
  validate_autounattend

  local iso_storage vm_storage mode vmid vm_name cores memory balloon disk_size bridge start_vm
  iso_storage="$(choose_storage iso "ISO STORAGE")"
  vm_storage="$(choose_storage images "VM DISK STORAGE")"
  mode="$(select_mode)"

  vmid="$(next_vmid)"
  vm_name="$DEFAULT_VM_NAME"
  cores="$DEFAULT_CORES"
  memory="$DEFAULT_MEMORY"
  balloon="$DEFAULT_BALLOON"
  disk_size="$DEFAULT_DISK_SIZE"
  bridge="$DEFAULT_BRIDGE"
  start_vm="yes"

  if ! prompt_yesno "SETTINGS" "Use default VM settings?\n\nVM ID: $vmid\nName: $vm_name\nCPU: $cores cores\nRAM: $memory MB\nBalloon minimum: $balloon MB\nDisk: $disk_size GB\nBridge: $bridge\n\nChoose No for Advanced settings."; then
    vmid="$(prompt_input "VM ID" "Virtual machine ID" "$vmid")"
    vm_name="$(prompt_input "VM NAME" "Proxmox VM name" "$vm_name")"
    cores="$(prompt_input "CPU CORES" "Number of CPU cores" "$cores")"
    memory="$(prompt_input "MEMORY" "Memory in MB" "$memory")"
    balloon="$(prompt_input "BALLOON" "Minimum balloon memory in MB (0 disables ballooning)" "$balloon")"
    disk_size="$(prompt_input "DISK SIZE" "Windows disk size in GB" "$disk_size")"
    bridge="$(prompt_input "NETWORK" "Proxmox bridge" "$bridge")"
    if ! prompt_yesno "START VM" "Start the VM immediately after creation?"; then
      start_vm="no"
    fi
  fi

  build_install_media "$iso_storage" "$mode"
  create_windows_vm "$vmid" "$vm_name" "$cores" "$memory" "$balloon" "$disk_size" "$bridge" "$vm_storage" "$iso_storage" "$mode" "$start_vm"
}
