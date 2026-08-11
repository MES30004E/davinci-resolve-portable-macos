#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "$SCRIPT_DIR/scripts/common.sh" ]]; then
  source "$SCRIPT_DIR/scripts/common.sh"
  source "$SCRIPT_DIR/scripts/update_helpers.sh"
  source "$SCRIPT_DIR/scripts/install_core.sh"
else
  source "$SCRIPT_DIR/common.sh"
  source "$SCRIPT_DIR/update_helpers.sh"
  source "$SCRIPT_DIR/install_core.sh"
fi

printf 'DaVinci Resolve Portable Updater\n'
progress_reset
progress_phase 5 "Detecting portable installation"
pkg="${1:-}"
root="${2:-}"
if [[ -n "$root" ]]; then
  root="$(normalize_path_input "$root")" || die "Invalid portable-root path."
  ensure_portable_root "$root"
  root="$(canonical_existing_dir "$root")"
  validate_managed_installation "$root" || die "The selected root is not a valid project-managed installation."
else
  root="$(select_managed_installation)"
fi

progress_phase 10 "Validating current installation"
run_with_status "Validating current installation" validate_managed_installation "$root" || \
  die "The current portable installation is invalid."
current_version="$(current_install_version "$root")"
current_app="$(current_install_app "$root")"
section "Current installation"
printf 'Version: %s\nApp:     %s\n' "$current_version" "$current_app"

if [[ -n "$pkg" ]]; then
  pkg="$(normalize_path_input "$pkg")" || die "Invalid installer path."
else
  pkg="$(prompt_path 'Drag the newer official DaVinci Resolve .pkg here, then press Return: ')"
fi
install_from_pkg update "$pkg" "$root"
if [[ -t 0 ]]; then printf '\nPress Return to close.'; read -r _; fi
