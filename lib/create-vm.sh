#!/usr/bin/env bash

# Create a Windows 11 VM using settings collected by install.sh.
# The hardware intentionally favors built-in Windows drivers:
#   - IDE system disk
#   - E1000 NIC
# This avoids needing a VirtIO driver ISO during initial installation.

create_windows_vm() {
  local vmid="$1" name="$2" cores="$3" memory="$4" balloon="$5" disk_size="$6"
  local bridge="$7" vm_storage="$8" iso_storage="$9" mode="${10}" start_vm="${11}"

  qm status "$vmid" >/dev/null 2>&1 && die "VM $vmid already exists."

  msg "Creating VM $vmid ($name)"

  qm create "$vmid" \
    --name "$name" \
    --ostype win11 \
    --machine q35 \
    --bios ovmf \
    --cpu host \
    --cores "$cores" \
    --sockets 1 \
    --memory "$memory" \
    --balloon "$balloon" \
    --numa 0 \
    --agent 1 \
    --scsihw virtio-scsi-single \
    --net0 "e1000,bridge=${bridge},firewall=1"

  # Create EFI first, main disk second, TPM third. The exact generated disk
  # suffixes are not relied upon, but this mirrors a typical Proxmox layout.
  qm set "$vmid" --efidisk0 "${vm_storage}:0,efitype=4m,ms-cert=2023k,pre-enrolled-keys=1"
  qm set "$vmid" --ide0 "${vm_storage}:${disk_size},discard=on,ssd=1"
  qm set "$vmid" --tpmstate0 "${vm_storage}:0,version=v2.0"

  if [[ "$mode" == single ]]; then
    qm set "$vmid" --ide2 "${iso_storage}:iso/${WINDOWS_SINGLE_NAME},media=cdrom"
    qm set "$vmid" --boot "order=ide0;ide2;net0"
  else
    qm set "$vmid" --ide1 "${iso_storage}:iso/${UNATTEND_ISO_NAME},media=cdrom"
    qm set "$vmid" --ide2 "${iso_storage}:iso/${WINDOWS_NOPROMPT_NAME},media=cdrom"
    qm set "$vmid" --boot "order=ide0;ide2;net0;ide1"
  fi

  msg "VM created successfully"
  qm config "$vmid"

  if [[ "$start_vm" == yes ]]; then
    msg "Starting VM $vmid"
    qm start "$vmid"
  fi
}
