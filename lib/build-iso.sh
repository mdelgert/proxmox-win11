#!/usr/bin/env bash

# Build Windows installation media.
#
# single mode:
#   - downloads Microsoft's original ISO if missing
#   - copies Autounattend.xml to the ISO root
#   - rebuilds with efisys_noprompt.bin
#   - result: windows11-autounattend.iso
#
# dual mode:
#   - builds windows11-noprompt.iso without embedding Autounattend.xml
#   - builds a tiny unattend.iso containing Autounattend.xml
#
# Both modes use Microsoft's efisys_noprompt.bin so OVMF/UEFI boots
# straight into Windows Setup without "Press any key to boot from CD/DVD".

build_install_media() {
  local iso_storage="$1" mode="$2"
  local source_iso source_path output_name output_path unattend_path

  source_iso="$WINDOWS_SOURCE_NAME"
  source_path="$(storage_path "$iso_storage" "$source_iso")"

  if [[ ! -s "$source_path" ]]; then
    msg "Downloading Windows 11 ISO from Microsoft"
    mkdir -p "$(dirname "$source_path")"
    wget -c "$WINDOWS_URL" -O "$source_path"
  else
    msg "Using existing Microsoft ISO: $source_iso"
  fi

  case "$mode" in
    single)
      output_name="$WINDOWS_SINGLE_NAME"
      output_path="$(storage_path "$iso_storage" "$output_name")"
      [[ -s "$output_path" ]] || rebuild_windows_iso "$source_path" "$output_path" yes
      ;;
    dual)
      output_name="$WINDOWS_NOPROMPT_NAME"
      output_path="$(storage_path "$iso_storage" "$output_name")"
      [[ -s "$output_path" ]] || rebuild_windows_iso "$source_path" "$output_path" no

      unattend_path="$(storage_path "$iso_storage" "$UNATTEND_ISO_NAME")"
      build_unattend_iso "$unattend_path"
      ;;
    *) die "Unknown install mode: $mode" ;;
  esac
}

rebuild_windows_iso() (
  set -euo pipefail
  local source_iso="$1" output_iso="$2" embed_unattend="$3"
  local work mnt
  work="$(mktemp -d)"
  mnt="$(mktemp -d)"

  cleanup_iso_build() {
    mountpoint -q "$mnt" 2>/dev/null && umount "$mnt" || true
    rm -rf "$work" "$mnt"
  }
  trap cleanup_iso_build EXIT

  msg "Preparing $(basename "$output_iso")"
  mount -o loop,ro "$source_iso" "$mnt"
  cp -a "$mnt"/. "$work"/
  umount "$mnt"

  [[ -f "$work/efi/microsoft/boot/efisys_noprompt.bin" ]] || die "efisys_noprompt.bin was not found in the Microsoft ISO."
  [[ -f "$work/boot/etfsboot.com" ]] || die "etfsboot.com was not found in the Microsoft ISO."

  if [[ "$embed_unattend" == yes ]]; then
    cp "$AUTOUNATTEND_XML" "$work/Autounattend.xml"
  fi

  xorriso -as mkisofs \
    -iso-level 3 \
    -J -joliet-long -R \
    -V WIN11 \
    -b boot/etfsboot.com \
    -no-emul-boot \
    -boot-load-size 8 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys_noprompt.bin \
    -no-emul-boot \
    -o "$output_iso" \
    "$work"

  msg "Created: $output_iso"
)

build_unattend_iso() (
  set -euo pipefail
  local output_iso="$1"
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # Always rebuild this tiny ISO so changes to Autounattend.xml are picked up.
  cp "$AUTOUNATTEND_XML" "$work/Autounattend.xml"
  xorriso -as mkisofs -J -R -V UNATTEND -o "$output_iso" "$work" >/dev/null
  msg "Created: $output_iso"
)
