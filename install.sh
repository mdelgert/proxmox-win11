#!/usr/bin/env bash
set -euo pipefail

# Entry point for the Proxmox Windows 11 helper.
#
# Two supported invocations:
#
#   cloned repository
#     ./install.sh
#
#   one-line launcher (repository is downloaded to a temp dir first)
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/mdelgert/proxmox-win11/main/install.sh)"
#
# Override REPO_SLUG / REPO_REF to bootstrap from a fork or branch, and
# AUTOUNATTEND_XML to point at an answer file outside the repository.

REPO_SLUG="${REPO_SLUG:-mdelgert/proxmox-win11}"
REPO_REF="${REPO_REF:-main}"

bootstrap_repo() {
  local tarball="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REPO_REF}"
  local cmd

  for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || {
      printf '\nERROR: %s is required to download the repository.\n' "$cmd" >&2
      exit 1
    }
  done

  ROOT_DIR="$(mktemp -d)"
  trap 'rm -rf "$ROOT_DIR"' EXIT

  printf '\n==> Downloading %s@%s\n' "$REPO_SLUG" "$REPO_REF"
  curl -fsSL "$tarball" | tar -xz -C "$ROOT_DIR" --strip-components=1 || {
    printf '\nERROR: Could not download %s\n' "$tarball" >&2
    exit 1
  }

  [[ -f "$ROOT_DIR/lib/common.sh" ]] || {
    printf '\nERROR: Downloaded archive does not contain lib/common.sh\n' >&2
    exit 1
  }
}

# BASH_SOURCE is unset when this script is read from stdin or `bash -c`,
# so fall back to downloading the rest of the project.
self="${BASH_SOURCE[0]:-}"
if [[ -n "$self" && -f "$(dirname -- "$self")/lib/common.sh" ]]; then
  ROOT_DIR="$(cd -- "$(dirname -- "$self")" && pwd)"
else
  bootstrap_repo
fi

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/build-iso.sh"
source "$ROOT_DIR/lib/create-vm.sh"

require_root
require_proxmox
install_dependencies

main_menu
