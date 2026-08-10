#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "$SCRIPT_DIR/scripts/common.sh" ]]; then
  source "$SCRIPT_DIR/scripts/common.sh"
  default_root=""
else
  source "$SCRIPT_DIR/common.sh"
  default_root="$(portable_root_from_script "$SCRIPT_DIR" || true)"
fi

root="${1:-$default_root}"
[[ -n "$root" ]] || root="$(prompt_path 'Drag the portable root here, then press Return: ')"
ensure_portable_root "$root"
root="$(canonical_existing_dir "$root")"
support="$root/$SUPPORT_RELATIVE"
state="$root/$STATE_RELATIVE"
launcher="$root/$APPS_RELATIVE/$LAUNCHER_NAME"
expected_app_link="$support/User"
expected_prefs_link="$support/User Preferences"
user_application_support_path="$(portable_user_application_support_path)"
user_preferences_path="$(portable_user_preferences_path)"
state_owned=0
if [[ -f "$state/portable-root" && "$(sed -n '1p' "$state/portable-root")" == "$root" ]]; then
  state_owned=1
fi

printf '%s\n' "This will remove the generated launcher and project-managed Resolve app files under:" "$root"
confirm 'Continue with uninstall?' || exit 0

remove_owned_symlink() {
  local path="$1" expected="$2" label="$3"
  if [[ -L "$path" && "$(readlink "$path")" == "$expected" ]]; then
    rm "$path"
    info "Removed project-created $label symlink."
  elif [[ -L "$path" ]]; then
    warn "Left $label symlink untouched because it targets a different path: $path"
  elif [[ -e "$path" ]]; then
    warn "Left $label path untouched because it is not the project symlink: $path"
  fi
}

remove_owned_symlink "$user_application_support_path" "$expected_app_link" "Application Support"
remove_owned_symlink "$user_preferences_path" "$expected_prefs_link" "Preferences"

if [[ -d "$launcher" ]]; then
  bundle_id="$(plist_value "$launcher/Contents/Info.plist" CFBundleIdentifier || true)"
  if [[ "$bundle_id" == "io.github.MES30004E.davinci-resolve-portable" ]]; then
    rm -rf "$launcher"
    info "Removed generated launcher."
  else
    warn "Launcher was not removed because its bundle identifier is not owned by this project."
  fi
fi

if [[ "$state_owned" -eq 1 && -f "$state/current-app" ]]; then
  current_app="$(sed -n '1p' "$state/current-app")"
  case "$current_app" in
    "$support"/DaVinci\ Resolve\ *.app)
      [[ -d "$current_app" ]] && rm -rf "$current_app"
      ;;
    *) warn "Ignored unsafe current-app state value: $current_app" ;;
  esac
fi

if [[ "$state_owned" -eq 1 && -d "$state/rollback" && ! -L "$state/rollback" ]]; then
  while IFS= read -r -d '' rollback; do
    case "$rollback" in
      "$state/rollback"/DaVinci\ Resolve\ *.app.*) rm -rf "$rollback" ;;
    esac
  done < <(find "$state/rollback" -mindepth 1 -maxdepth 1 -type d -print0)
fi

if [[ "$state_owned" -eq 1 ]]; then
  if confirm 'Also delete portable User and User Preferences data? This cannot be undone'; then
    [[ "$support/User" == "$root/"* ]] && rm -rf "$support/User"
    [[ "$support/User Preferences" == "$root/"* ]] && rm -rf "$support/User Preferences"
    info "Deleted portable user data at your request."
  else
    info "Preserved portable user data under: $support"
  fi
else
  warn "User data was preserved because the selected root could not be verified as owned by this project."
fi

if [[ "$state_owned" -eq 1 && -d "$state" && ! -L "$state" ]]; then
  rm -rf "$state"
elif [[ -e "$state" || -L "$state" ]]; then
  warn "Private state was left untouched because its ownership marker did not match."
fi
info "Uninstall complete. Other Blackmagic support payloads were left untouched."
if [[ -t 0 ]]; then printf '\nPress Return to close.'; read -r _; fi
