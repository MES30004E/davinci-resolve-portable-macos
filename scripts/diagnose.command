#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "$SCRIPT_DIR/common.sh" ]]; then
  source "$SCRIPT_DIR/common.sh"
  default_root="$(portable_root_from_script "$SCRIPT_DIR" || true)"
else
  source "$SCRIPT_DIR/scripts/common.sh"
  default_root=""
fi

root="${1:-$default_root}"
[[ -n "$root" ]] || root="$(prompt_path 'Drag the portable root here, then press Return: ')"
if ! ensure_portable_root "$root"; then exit 1; fi
root="$(canonical_existing_dir "$root")"
support="$root/$SUPPORT_RELATIVE"
launcher="$root/$APPS_RELATIVE/$LAUNCHER_NAME"
state="$root/$STATE_RELATIVE"
user_application_support_path="$(portable_user_application_support_path)"
user_preferences_path="$(portable_user_preferences_path)"
app=""
[[ -f "$state/current-app" ]] && app="$(sed -n '1p' "$state/current-app")"
if [[ -z "$app" || ! -d "$app" ]]; then
  app="$(find "$support" -mindepth 1 -maxdepth 1 -type d -name 'DaVinci Resolve *.app' -print -quit 2>/dev/null)"
fi

heading() { printf '\n=== %s ===\n' "$1"; }
heading 'System'
sw_vers 2>/dev/null || true
printf 'Architecture: %s\n' "$(uname -m)"
printf 'Portable root: %s\n' "$root"
printf 'Filesystem: %s\n' "$(diskutil info "$root" 2>/dev/null | awk -F: '/File System Personality/{sub(/^[[:space:]]+/,"",$2); print $2; exit}')"

heading 'Resolve'
printf 'Path: %s\n' "${app:-not found}"
if [[ -n "$app" && -d "$app" ]]; then
  printf 'Version: %s\n' "$(resolve_version "$app" 2>/dev/null || printf 'unknown')"
  dylib="$app/Contents/Frameworks/$DYLIB_NAME"
  executable="$app/Contents/MacOS/Resolve"
  printf 'Redirect dylib: %s\n' "$dylib"
  file "$dylib" 2>&1 || true
  codesign -dvv "$dylib" 2>&1 || true
  printf '\nResolve executable signature and flags:\n'
  codesign -dvvv "$executable" 2>&1 || true
  printf '\nResolve executable entitlements:\n'
  codesign -d --entitlements :- "$executable" 2>/dev/null || true
  printf '\nStrict validation:\n'
  codesign --verify --strict --verbose=2 "$executable" 2>&1 || true
  codesign --verify --strict --verbose=2 "$dylib" 2>&1 || true
fi

heading 'Launcher'
if [[ -f "$launcher/Contents/Info.plist" ]]; then
  printf 'Path: %s\n' "$launcher"
  for key in CFBundleIdentifier CFBundleName CFBundleDisplayName CFBundleIconFile CFBundleIconName NSRemovableVolumesUsageDescription; do
    printf '%s: %s\n' "$key" "$(plist_value "$launcher/Contents/Info.plist" "$key" 2>/dev/null || printf '(not set)')"
  done
  codesign --verify --strict --verbose=2 "$launcher" 2>&1 || true
else
  printf 'Not found: %s\n' "$launcher"
fi

heading 'User symlinks'
for record in \
  "$user_application_support_path|$support/User|Application Support" \
  "$user_preferences_path|$support/User Preferences|Preferences"
do
  path="${record%%|*}"; rest="${record#*|}"; expected="${rest%%|*}"; label="${record##*|}"
  printf '%s: %s' "$label" "$(symlink_state "$path" "$expected")"
  [[ -L "$path" ]] && printf ' -> %s' "$(readlink "$path")"
  printf '\n'
done

if [[ "${2:-}" == "--dyld-test" ]]; then
  heading 'Optional DYLD library-load validation'
  if [[ -n "$app" && -x "$executable" && -f "$dylib" ]]; then
    warn "This launches Resolve with DYLD_PRINT_LIBRARIES and writes a log under /tmp."
    if confirm 'Launch now?'; then
      log="/tmp/davinci-resolve-portable-dyld.log"
      DYLD_PRINT_LIBRARIES=1 DYLD_INSERT_LIBRARIES="$dylib" "$executable" >"$log" 2>&1 &
      printf 'Started Resolve. Inspect: %s\n' "$log"
    fi
  fi
fi
