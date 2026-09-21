#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/build-iso.sh"
source "$ROOT_DIR/lib/create-vm.sh"

require_root
require_proxmox
install_dependencies

main_menu
