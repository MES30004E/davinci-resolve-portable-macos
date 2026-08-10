#!/bin/bash

# Shared helpers. This file is sourced; callers enable their own shell options.
PROJECT_NAME="davinci-resolve-portable-macos"
SUPPORT_RELATIVE="Application Support/Blackmagic Design"
APPS_RELATIVE="SSD Apps"
LAUNCHER_NAME="DaVinci Resolve.app"
DYLIB_NAME="resolve-redirect.dylib"
STATE_RELATIVE=".davinci-resolve-portable"
PROGRESS_LAST_PERCENT=0
RUN_STATUS_PID=""
RUN_STATUS_INTERRUPTED=0

info() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This project requires macOS."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required macOS tool not found: $1"
}

canonical_existing_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  (cd "$dir" && pwd -P)
}

trim_dragged_path() {
  local value="$1"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s\n' "$value"
}

prompt_path() {
  local prompt="$1" value
  printf '%s' "$prompt" >&2
  IFS= read -r value
  trim_dragged_path "$value"
}

confirm() {
  local prompt="$1" answer
  printf '%s [y/N] ' "$prompt" >&2
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

progress_reset() {
  PROGRESS_LAST_PERCENT=0
}

progress_phase() {
  local percent="$1" label="$2" filled empty bar position
  [[ "$percent" =~ ^[0-9]+$ ]] || {
    warn "Invalid progress percentage: $percent"
    return 1
  }
  (( percent >= 0 && percent <= 100 )) || {
    warn "Progress percentage is outside 0-100: $percent"
    return 1
  }
  if (( percent < PROGRESS_LAST_PERCENT )); then
    warn "Progress cannot move backwards from $PROGRESS_LAST_PERCENT% to $percent%."
    return 1
  fi
  PROGRESS_LAST_PERCENT="$percent"
  filled=$((percent * 20 / 100))
  empty=$((20 - filled))
  bar=""
  for ((position=0; position<filled; position++)); do bar="${bar}#"; done
  for ((position=0; position<empty; position++)); do bar="${bar}-"; done
  printf '[%s] %3d%% %s\n' "$bar" "$percent" "$label"
}

progress_animation_enabled() {
  [[ "${DAVINCI_PORTABLE_NO_ANIMATION:-0}" != "1" && -t 1 ]]
}

_run_status_interrupt() {
  RUN_STATUS_INTERRUPTED=1
  if [[ -n "$RUN_STATUS_PID" ]]; then
    kill -INT "$RUN_STATUS_PID" 2>/dev/null || true
  fi
}

run_with_status() {
  local label="$1" status start now elapsed minutes seconds frame_idx frame
  local saved_int saved_term
  shift

  if ! progress_animation_enabled; then
    info "$label..."
    if "$@"; then
      return 0
    else
      status=$?
      printf '[FAILED] %s\n' "$label" >&2
      return "$status"
    fi
  fi

  start="$(date +%s)"
  RUN_STATUS_INTERRUPTED=0
  "$@" &
  RUN_STATUS_PID=$!
  saved_int="$(trap -p INT || true)"
  saved_term="$(trap -p TERM || true)"
  trap _run_status_interrupt INT TERM
  frame_idx=0

  while kill -0 "$RUN_STATUS_PID" 2>/dev/null; do
    case "$frame_idx" in
      0) frame='|' ;;
      1) frame='/' ;;
      2) frame='-' ;;
      *) frame='\\' ;;
    esac
    now="$(date +%s)"
    elapsed=$((now - start))
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))
    printf '\r[%s] %s... %02d:%02d elapsed' "$frame" "$label" "$minutes" "$seconds"
    frame_idx=$(((frame_idx + 1) % 4))
    sleep 0.2
  done

  if wait "$RUN_STATUS_PID"; then
    status=0
  else
    status=$?
  fi
  [[ "$RUN_STATUS_INTERRUPTED" -eq 0 ]] || status=130
  RUN_STATUS_PID=""
  if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
  if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
  printf '\r%100s\r' ''

  if [[ "$status" -ne 0 ]]; then
    printf '[FAILED] %s\n' "$label" >&2
  fi
  return "$status"
}

run_with_visible_output() {
  local label="$1" status
  shift
  info "$label..."
  if "$@"; then
    return 0
  else
    status=$?
    printf '[FAILED] %s\n' "$label" >&2
    return "$status"
  fi
}

portable_user_home() {
  local selected_home
  selected_home="${DAVINCI_PORTABLE_HOME_OVERRIDE:-${HOME:-}}"
  [[ -n "$selected_home" ]] || die "Could not determine the user home directory."
  [[ "$selected_home" == /* ]] || die "User home directory must be an absolute path: $selected_home"
  [[ "$selected_home" != "/" ]] || die "Refusing to use the filesystem root as the user home directory."
  selected_home="${selected_home%/}"
  printf '%s\n' "$selected_home"
}

portable_user_application_support_path() {
  printf '%s/Library/Application Support/Blackmagic Design\n' "$(portable_user_home)"
}

portable_user_preferences_path() {
  printf '%s/Library/Preferences/Blackmagic Design\n' "$(portable_user_home)"
}

ensure_portable_root() {
  local root="$1"
  [[ -n "$root" ]] || die "Portable root cannot be empty."
  [[ "$root" == /* ]] || die "Portable root must be an absolute path."
  case "$root" in
    /|/Applications|/Library|/System|/Users|/Volumes|/usr|/bin|/sbin|/private|"$HOME")
      die "Refusing unsafe portable root: $root"
      ;;
  esac
  [[ -d "$root" ]] || die "Portable root is not a directory: $root"
  [[ -w "$root" ]] || die "Portable root is not writable: $root"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

plist_boolean_is_true() {
  local plist="$1" key="$2" value
  value="$(plist_value "$plist" "$key" || true)"
  [[ "$value" == "true" ]]
}

code_signature_has_runtime() {
  local details="$1"
  case "$details" in
    *flags=*\(*runtime*\)*) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_signing_option() {
  if code_signature_has_runtime "$1"; then
    printf '%s\n' '--options runtime'
  fi
}

executable_entitlement_is_true() {
  local executable="$1" key="$2" entitlements result
  entitlements="$(mktemp "${TMPDIR:-/tmp}/resolve-entitlements-check.XXXXXX")" || return 1
  if codesign -d --entitlements :- "$executable" >"$entitlements" 2>/dev/null && \
     plutil -lint "$entitlements" >/dev/null 2>&1 && \
     plist_boolean_is_true "$entitlements" "$key"; then
    result=0
  else
    result=1
  fi
  rm -f "$entitlements"
  return "$result"
}

macho_has_architecture() {
  local binary="$1" required_arch="$2" arch
  while IFS= read -r arch; do
    [[ "$arch" == "$required_arch" ]] && return 0
  done < <(lipo -archs "$binary" 2>/dev/null | tr ' ' '\n')
  return 1
}

available_bytes() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

file_size_bytes() {
  stat -f '%z' "$1" 2>/dev/null
}

tree_size_bytes() {
  local path="$1" kilobytes
  kilobytes="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  [[ "$kilobytes" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((kilobytes * 1024))"
}

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " "); unit_idx = 1;
    while (bytes >= 1024 && unit_idx < 5) { bytes /= 1024; unit_idx++ }
    printf "%.1f %s", bytes, units[unit_idx]
  }'
}

require_free_space() {
  local label="$1" path="$2" required="$3" available
  available="$(available_bytes "$path" || true)"
  [[ "$available" =~ ^[0-9]+$ ]] || {
    warn "Could not determine free space for $label at: $path"
    return 0
  }
  info "$label free space: $(human_bytes "$available"); conservative requirement: $(human_bytes "$required")."
  if (( available < required )); then
    die "Insufficient free space for $label at: $path"
  fi
}

managed_portable_root_exists() {
  local root="$1" marker
  marker="$root/$STATE_RELATIVE/portable-root"
  [[ -f "$marker" ]] || return 1
  [[ "$(sed -n '1p' "$marker")" == "$root" ]]
}

resolve_version() {
  local app="$1" version
  version="$(plist_value "$app/Contents/Info.plist" CFBundleShortVersionString || true)"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

find_resolve_app() {
  local expanded="$1" candidate identifier
  while IFS= read -r -d '' candidate; do
    [[ -f "$candidate/Contents/MacOS/Resolve" ]] || continue
    identifier="$(plist_value "$candidate/Contents/Info.plist" CFBundleIdentifier || true)"
    if [[ "$identifier" == *DaVinciResolve* || "$identifier" == *davinci* || -z "$identifier" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$expanded" -type d -name 'DaVinci Resolve.app' -print0)
  return 1
}

find_support_payloads() {
  local expanded="$1" directory
  while IFS= read -r -d '' directory; do
    case "$directory" in
      */Library/Application\ Support/Blackmagic\ Design)
        printf '%s\0' "$directory"
        ;;
    esac
  done < <(find "$expanded" -type d -name 'Blackmagic Design' -print0)
}

symlink_state() {
  local path="$1" expected="$2" actual
  if [[ -L "$path" ]]; then
    actual="$(readlink "$path")"
    if [[ "$actual" == "$expected" ]]; then
      [[ -e "$path" ]] && printf 'valid\n' || printf 'expected-broken\n'
    else
      [[ -e "$path" ]] && printf 'other-symlink\n' || printf 'stale-symlink\n'
    fi
  elif [[ -d "$path" ]]; then
    if [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      printf 'empty-directory\n'
    else
      printf 'nonempty-directory\n'
    fi
  elif [[ -e "$path" ]]; then
    printf 'other-path\n'
  else
    printf 'missing\n'
  fi
}

prepare_user_symlink() {
  local path="$1" target="$2" label="$3" state
  state="$(symlink_state "$path" "$target")"
  case "$state" in
    valid) info "$label symlink is already correct." ;;
    expected-broken)
      mkdir -p "$target"
      info "$label symlink target was restored."
      ;;
    missing)
      mkdir -p "$(dirname "$path")" "$target"
      ln -s "$target" "$path"
      info "Created $label symlink."
      ;;
    empty-directory)
      rmdir "$path"
      ln -s "$target" "$path"
      info "Replaced empty $label directory with the portable symlink."
      ;;
    nonempty-directory)
      die "$label contains existing data: $path
Nothing was moved or deleted. Back it up and migrate it deliberately before retrying; see docs/troubleshooting.md."
      ;;
    other-symlink|stale-symlink)
      die "$label is a symlink to a different location: $path -> $(readlink "$path")
Nothing was changed. Resolve this path manually before retrying."
      ;;
    *) die "$label exists but is not a directory or symlink: $path" ;;
  esac
}

preflight_user_symlink() {
  local path="$1" target="$2" label="$3" state
  state="$(symlink_state "$path" "$target")"
  case "$state" in
    valid|expected-broken|missing|empty-directory) return 0 ;;
    nonempty-directory)
      die "$label contains existing data: $path
Nothing was moved or deleted. Back it up and migrate it deliberately before retrying; see docs/troubleshooting.md."
      ;;
    other-symlink|stale-symlink)
      die "$label is a symlink to a different location: $path -> $(readlink "$path")
Nothing was changed. Resolve this path manually before retrying."
      ;;
    *) die "$label exists but is not a directory or symlink: $path" ;;
  esac
}

validate_resolve_app() {
  local app="$1" dylib executable
  dylib="$app/Contents/Frameworks/$DYLIB_NAME"
  executable="$app/Contents/MacOS/Resolve"
  [[ -d "$app" ]] || return 1
  [[ -x "$executable" ]] || return 1
  [[ -f "$app/Contents/Info.plist" ]] || return 1
  [[ -f "$dylib" ]] || return 1
  plutil -lint "$app/Contents/Info.plist" >/dev/null || return 1
  macho_has_architecture "$dylib" arm64 || return 1
  codesign --verify --strict "$executable" >/dev/null 2>&1 || return 1
  codesign --verify --strict "$dylib" >/dev/null 2>&1 || return 1
  executable_entitlement_is_true "$executable" \
    com.apple.security.cs.allow-dyld-environment-variables || return 1
  executable_entitlement_is_true "$executable" \
    com.apple.security.cs.disable-library-validation || return 1
}

portable_root_from_script() {
  local script_dir="$1"
  if [[ "$script_dir" == */"$STATE_RELATIVE/bin" ]]; then
    dirname "$(dirname "$script_dir")"
  else
    return 1
  fi
}
