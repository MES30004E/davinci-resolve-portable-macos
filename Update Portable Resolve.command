#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "$SCRIPT_DIR/scripts/common.sh" ]]; then
  source "$SCRIPT_DIR/scripts/common.sh"
  source "$SCRIPT_DIR/scripts/install_core.sh"
  default_root=""
else
  source "$SCRIPT_DIR/common.sh"
  source "$SCRIPT_DIR/install_core.sh"
  default_root="$(portable_root_from_script "$SCRIPT_DIR" || true)"
fi

pkg="${1:-}"
root="${2:-$default_root}"
[[ -n "$pkg" ]] || pkg="$(prompt_path 'Drag the newer official DaVinci Resolve .pkg here, then press Return: ')"
[[ -n "$root" ]] || root="$(prompt_path 'Drag the existing portable root here, then press Return: ')"
install_from_pkg update "$pkg" "$root"
if [[ -t 0 ]]; then printf '\nPress Return to close.'; read -r _; fi
