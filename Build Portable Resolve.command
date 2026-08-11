#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/scripts/common.sh"
source "$SCRIPT_DIR/scripts/install_core.sh"

printf 'DaVinci Resolve Portable Builder\n'
pkg="${1:-}"
root="${2:-}"
[[ -n "$pkg" ]] || pkg="$(prompt_path 'Drag the official DaVinci Resolve .pkg here, then press Return: ')"
[[ -n "$root" ]] || root="$(prompt_path 'Drag the portable drive root/folder here, then press Return: ')"
install_from_pkg build "$pkg" "$root"
if [[ -t 0 ]]; then printf '\nPress Return to close.'; read -r _; fi
