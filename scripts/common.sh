#!/bin/bash

# Shared helpers. This file is sourced; callers enable their own shell options.
PROJECT_NAME="davinci-resolve-portable-macos"
SUPPORT_RELATIVE="Application Support/Blackmagic Design"
APPS_RELATIVE="SSD Apps"
LAUNCHER_NAME="DaVinci Resolve.app"
DYLIB_NAME="resolve-redirect.dylib"
STATE_RELATIVE=".davinci-resolve-portable"
PROGRESS_LAST_PERCENT=0
PROGRESS_CURRENT_LABEL=""
RUN_STATUS_PID=""
RUN_STATUS_INTERRUPTED=0
UI_DASHBOARD_ACTIVE=0
UI_DASHBOARD_ROWS=13
UI_DASHBOARD_SPINNER_INDEX=0
UI_DASHBOARD_OPERATION=""
UI_DASHBOARD_OPERATION_PERCENT=""
UI_DASHBOARD_COMPLETED=0
UI_DASHBOARD_TOTAL=0
UI_DASHBOARD_RATE=""
UI_DASHBOARD_OPERATION_ETA=""
UI_DASHBOARD_CURRENT_FILE=""
UI_DASHBOARD_DETAIL=""
UI_RUN_STARTED_AT=0
UI_PHASE_STARTED_AT=0
UI_PHASE_SAMPLE_COUNT=0
UI_PHASE_SCALE_PERCENT=100
UI_OVERALL_ETA_SECONDS=""
UI_OVERALL_ETA_UPDATED_AT=0
UI_OPERATION_BASE_PERCENT=0
COPY_MONITOR_LIST=""
COPY_MONITOR_PENDING=""
COPY_MONITOR_SOURCE=""
COPY_MONITOR_DESTINATION=""
COPY_MONITOR_COMPLETE=0
COPY_MONITOR_PREFIX='+'
COPY_MONITOR_ACTION='copy'

info() { ui_dashboard_end; printf '==> %s\n' "$*"; }
warn() { ui_dashboard_end; printf 'Warning: %s\n' "$*" >&2; }
die() { ui_dashboard_end; printf 'Error: %s\n' "$*" >&2; exit 1; }

output_is_interactive() {
  [[ "${DAVINCI_PORTABLE_NO_ANIMATION:-0}" != "1" ]] || return 1
  [[ "${DAVINCI_PORTABLE_FORCE_INTERACTIVE:-0}" == "1" || -t 1 ]]
}

dashboard_capable() {
  output_is_interactive || return 1
  [[ "${TERM:-dumb}" != "dumb" ]] || return 1
  command -v tput >/dev/null 2>&1 || return 1
  tput cols >/dev/null 2>&1
}

verbose_output_enabled() {
  [[ "${DAVINCI_PORTABLE_VERBOSE:-0}" == "1" ]]
}

section() {
  ui_dashboard_end
  printf '\n-- %s %s\n\n' "$1" '----------------------------------------'
}

activity() {
  local prefix="$1" action="$2"
  shift 2
  ui_dashboard_end
  printf '%s %-9s %s\n' "$prefix" "$action" "$*"
}

validation_ok() {
  ui_dashboard_end
  printf '✓ validate  %s\n' "$*"
}

completed_action() {
  ui_dashboard_end
  printf '✓ %-9s %s\n' "$1" "$2"
}

quote_command_argument() {
  printf '%q' "$1"
}

log_command() {
  local argument separator=''
  verbose_output_enabled || return 0
  printf '$ '
  for argument in "$@"; do
    printf '%s' "$separator"
    quote_command_argument "$argument"
    separator=' '
  done
  printf '\n'
}

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

files_are_same() {
  local source="$1" destination="$2"
  [[ -e "$source" && -e "$destination" ]] || return 1
  [[ "$source" -ef "$destination" ]]
}

copy_project_runtime_file() {
  local source="$1" destination="$2" label="${3:-$(basename "$2")}" staged status
  [[ -f "$source" ]] || {
    warn "Project runtime source is missing or is not a file: $source"
    return 1
  }
  if files_are_same "$source" "$destination"; then
    activity '=' 'keep' "installed helper: $label"
    return 0
  fi
  [[ ! -d "$destination" ]] || {
    warn "Project runtime destination is a directory: $destination"
    return 1
  }
  mkdir -p "$(dirname "$destination")" || return 1
  staged="${destination}.new.$$"
  [[ ! -e "$staged" && ! -L "$staged" ]] || {
    warn "Temporary runtime destination already exists: $staged"
    return 1
  }
  activity '~' 'update' "installed helper: $label"
  log_command cp -p "$source" "$staged"
  if cp -p "$source" "$staged"; then
    log_command mv -f "$staged" "$destination"
    if mv -f "$staged" "$destination"; then
      return 0
    else
      status=$?
    fi
  else
    status=$?
  fi
  rm -f "$staged"
  return "$status"
}

normalize_path_input() {
  local value="$1" first last result character position escaped
  [[ "$value" != *$'\n'* ]] || return 1
  while [[ -n "$value" && "$value" == [[:space:]]* ]]; do value="${value#?}"; done
  while [[ -n "$value" && "$value" == *[[:space:]] ]]; do value="${value%?}"; done
  [[ -n "$value" ]] || return 1

  first="${value:0:1}"
  last="${value: -1}"
  if [[ "$first" == "'" || "$first" == '"' ]]; then
    [[ "$last" == "$first" && ${#value} -ge 2 ]] || return 1
    value="${value:1:${#value}-2}"
  fi

  result=""
  escaped=0
  for ((position=0; position<${#value}; position++)); do
    character="${value:$position:1}"
    if [[ "$escaped" -eq 1 ]]; then
      result="${result}${character}"
      escaped=0
    elif [[ "$character" == "\\" ]]; then
      escaped=1
    else
      result="${result}${character}"
    fi
  done
  [[ "$escaped" -eq 0 && -n "$result" && "$result" == /* ]] || return 1
  printf '%s\n' "$result"
}

trim_dragged_path() {
  normalize_path_input "$1"
}

prompt_path() {
  local prompt="$1" value
  ui_dashboard_end
  printf '%s' "$prompt" >&2
  IFS= read -r value
  normalize_path_input "$value" || die "Invalid path input. Paste an absolute path and do not leave an unmatched quote or trailing backslash."
}

confirm() {
  local prompt="$1" answer
  ui_dashboard_end
  printf '%s [y/N] ' "$prompt" >&2
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

progress_reset() {
  PROGRESS_LAST_PERCENT=0
  PROGRESS_CURRENT_LABEL=""
  UI_RUN_STARTED_AT="$(date +%s)"
  UI_PHASE_STARTED_AT="$UI_RUN_STARTED_AT"
  UI_PHASE_SAMPLE_COUNT=0
  UI_PHASE_SCALE_PERCENT=100
  UI_OVERALL_ETA_SECONDS=""
  UI_OVERALL_ETA_UPDATED_AT=0
  UI_OPERATION_BASE_PERCENT=0
}

progress_bar() {
  local percent="$1" filled empty bar position
  filled=$((percent * 20 / 100))
  empty=$((20 - filled))
  bar=""
  for ((position=0; position<filled; position++)); do bar="${bar}#"; done
  for ((position=0; position<empty; position++)); do bar="${bar}-"; done
  printf '%s' "$bar"
}

terminal_columns() {
  local columns
  columns="$(tput cols 2>/dev/null || true)"
  [[ "$columns" =~ ^[0-9]+$ && "$columns" -ge 40 ]] || columns=80
  printf '%s' "$columns"
}

truncate_dashboard_text() {
  local value="$1" maximum="$2" head tail
  if (( ${#value} <= maximum )); then printf '%s' "$value"; return 0; fi
  head=$((maximum / 3))
  tail=$((maximum - head - 3))
  printf '%s...%s' "${value:0:head}" "${value: -tail}"
}

phase_fallback_seconds() {
  case "$1" in
    *signature*) printf 8 ;;
    *disk\ space*|*paths*|*Preflight*) printf 5 ;;
    *Expanding*) printf 90 ;;
    *Preparing\ Resolve*) printf 120 ;;
    *redirect*) printf 20 ;;
    *Signing*) printf 35 ;;
    *rollback\ backup*) printf 120 ;;
    *support*) printf 35 ;;
    *launcher*) printf 20 ;;
    *Validating*) printf 25 ;;
    *symlink*) printf 5 ;;
    *) printf 15 ;;
  esac
}

remaining_fallback_seconds() {
  local percent="$1"
  if (( percent < 15 )); then printf 500
  elif (( percent < 40 )); then printf 450
  elif (( percent < 60 )); then printf 330
  elif (( percent < 70 )); then printf 210
  elif (( percent < 78 )); then printf 170
  elif (( percent < 84 )); then printf 140
  elif (( percent < 90 )); then printf 110
  elif (( percent < 96 )); then printf 55
  elif (( percent < 100 )); then printf 20
  else printf 0
  fi
}

ui_update_overall_eta() {
  local operation_eta="${1:-0}" now remaining candidate current_percent
  now="$(date +%s)"
  (( now > UI_OVERALL_ETA_UPDATED_AT )) || return 0
  UI_OVERALL_ETA_UPDATED_AT="$now"
  if (( UI_PHASE_SAMPLE_COUNT == 0 )); then
    UI_OVERALL_ETA_SECONDS=""
    return 0
  fi
  current_percent="${UI_DISPLAY_PERCENT:-$PROGRESS_LAST_PERCENT}"
  remaining="$(remaining_fallback_seconds "$current_percent")"
  candidate=$((remaining * UI_PHASE_SCALE_PERCENT / 100 + operation_eta))
  (( candidate >= 0 )) || candidate=0
  if [[ "$UI_OVERALL_ETA_SECONDS" =~ ^[0-9]+$ ]]; then
    UI_OVERALL_ETA_SECONDS=$((UI_OVERALL_ETA_SECONDS * 3 / 4 + candidate / 4))
  else
    UI_OVERALL_ETA_SECONDS="$candidate"
  fi
}

ui_overall_eta_text() {
  if [[ "$UI_OVERALL_ETA_SECONDS" =~ ^[0-9]+$ ]]; then
    printf '~%s' "$(format_duration "$UI_OVERALL_ETA_SECONDS")"
  else
    printf 'estimating...'
  fi
}

ui_dashboard_render() {
  local columns width bar copy_bar spinner elapsed overall_percent operation_percent line state state_extra
  [[ "$UI_DASHBOARD_ACTIVE" -eq 1 ]] || return 0
  columns="$(terminal_columns)"
  width=$((columns - 1))
  overall_percent="${UI_DISPLAY_PERCENT:-$PROGRESS_LAST_PERCENT}"
  bar="$(progress_bar "$overall_percent")"
  case "$UI_DASHBOARD_SPINNER_INDEX" in
    0) spinner='◐' ;; 1) spinner='◓' ;; 2) spinner='◑' ;; *) spinner='◒' ;;
  esac
  UI_DASHBOARD_SPINNER_INDEX=$(((UI_DASHBOARD_SPINNER_INDEX + 1) % 4))
  elapsed=$(( $(date +%s) - UI_RUN_STARTED_AT ))
  printf '\033[%dA' "$UI_DASHBOARD_ROWS"
  line="Overall  [$bar] ${overall_percent}%"
  printf '\033[2K%s\n' "$(truncate_dashboard_text "$line" "$width")"
  printf '\033[2KTime left  %s\n' "$(ui_overall_eta_text)"
  printf '\033[2KPhase    %s\n' "$(truncate_dashboard_text "$PROGRESS_CURRENT_LABEL" "$((width - 9))")"
  printf '\033[2KElapsed  %s\n' "$(format_duration "$elapsed")"
  printf '\033[2K\n'
  if [[ "$UI_DASHBOARD_OPERATION_PERCENT" =~ ^[0-9]+$ ]]; then
    operation_percent="$UI_DASHBOARD_OPERATION_PERCENT"
    copy_bar="$(progress_bar "$operation_percent")"
    printf '\033[2K%s     [%s] %s%%\n' "$UI_DASHBOARD_OPERATION" "$copy_bar" "$operation_percent"
    line="$(human_bytes "$UI_DASHBOARD_COMPLETED") / $(human_bytes "$UI_DASHBOARD_TOTAL")"
    [[ -n "$UI_DASHBOARD_RATE" ]] && line="$line   $UI_DASHBOARD_RATE"
    printf '\033[2K%s\n' "$(truncate_dashboard_text "$line" "$width")"
    if (( UI_DASHBOARD_COMPLETED >= UI_DASHBOARD_TOTAL && UI_DASHBOARD_TOTAL > 0 )); then
      state='Finalizing files...'
      state_extra='Time left  unavailable'
    else
      state="Time left  ${UI_DASHBOARD_OPERATION_ETA:-estimating...}"
      state_extra=''
    fi
  else
    printf '\033[2K%s\n' "${UI_DASHBOARD_OPERATION:-Progress   indeterminate}"
    printf '\033[2K%s\n' "$(truncate_dashboard_text "$UI_DASHBOARD_DETAIL" "$width")"
    state='Time left  unavailable'
    state_extra=''
  fi
  printf '\033[2K%s\n' "$(truncate_dashboard_text "$state" "$width")"
  printf '\033[2K%s\n' "$(truncate_dashboard_text "$state_extra" "$width")"
  printf '\033[2KCurrent file:\n'
  printf '\033[2K%s\n' "$(truncate_dashboard_text "${UI_DASHBOARD_CURRENT_FILE:-(waiting for filesystem activity)}" "$width")"
  printf '\033[2K\n'
  printf '\033[2KWorking  %s\n' "$spinner"
}

ui_dashboard_begin() {
  dashboard_capable || return 1
  UI_DASHBOARD_ACTIVE=1
  UI_DASHBOARD_SPINNER_INDEX=0
  printf '\033[?25l'
  for ((UI_DASHBOARD_ROW=0; UI_DASHBOARD_ROW<UI_DASHBOARD_ROWS; UI_DASHBOARD_ROW++)); do printf '\n'; done
  ui_dashboard_render
}

ui_dashboard_end() {
  local row
  [[ "$UI_DASHBOARD_ACTIVE" -eq 1 ]] || return 0
  printf '\033[%dA' "$UI_DASHBOARD_ROWS"
  for ((row=0; row<UI_DASHBOARD_ROWS; row++)); do printf '\033[2K\n'; done
  printf '\033[%dA\033[?25h' "$UI_DASHBOARD_ROWS"
  UI_DASHBOARD_ACTIVE=0
}

ui_dashboard_set_indeterminate() {
  UI_DASHBOARD_OPERATION="$1"
  UI_DASHBOARD_OPERATION_PERCENT=""
  UI_DASHBOARD_DETAIL="${2:-}"
  UI_DASHBOARD_CURRENT_FILE="${3:-}"
}

ui_dashboard_set_copy() {
  UI_DASHBOARD_OPERATION="$1"
  UI_DASHBOARD_OPERATION_PERCENT="$2"
  UI_DASHBOARD_COMPLETED="$3"
  UI_DASHBOARD_TOTAL="$4"
  UI_DASHBOARD_RATE="$5"
  UI_DASHBOARD_OPERATION_ETA="$6"
  UI_DASHBOARD_CURRENT_FILE="$7"
  UI_DASHBOARD_DETAIL=""
}

progress_phase() {
  local percent="$1" label="$2" bar now observed expected
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
  now="$(date +%s)"
  if [[ -n "$PROGRESS_CURRENT_LABEL" && "$UI_PHASE_STARTED_AT" -gt 0 ]]; then
    observed=$((now - UI_PHASE_STARTED_AT))
    expected="$(phase_fallback_seconds "$PROGRESS_CURRENT_LABEL")"
    if (( observed > 0 && expected > 0 )); then
      UI_PHASE_SAMPLE_COUNT=$((UI_PHASE_SAMPLE_COUNT + 1))
      UI_PHASE_SCALE_PERCENT=$((UI_PHASE_SCALE_PERCENT * 3 / 4 + observed * 100 / expected / 4))
      (( UI_PHASE_SCALE_PERCENT >= 40 )) || UI_PHASE_SCALE_PERCENT=40
      (( UI_PHASE_SCALE_PERCENT <= 300 )) || UI_PHASE_SCALE_PERCENT=300
    fi
  fi
  UI_PHASE_STARTED_AT="$now"
  PROGRESS_LAST_PERCENT="$percent"
  UI_OPERATION_BASE_PERCENT="$percent"
  PROGRESS_CURRENT_LABEL="$label"
  bar="$(progress_bar "$percent")"
  ui_update_overall_eta 0
  if ! dashboard_capable; then
    printf '[%3d%%] %s\n' "$percent" "$label"
  fi
}

progress_animation_enabled() {
  output_is_interactive
}

_run_status_interrupt() {
  RUN_STATUS_INTERRUPTED=1
  ui_dashboard_end
  if [[ -n "$RUN_STATUS_PID" ]]; then
    kill -INT "$RUN_STATUS_PID" 2>/dev/null || true
  fi
}

run_with_status() {
  local label="$1" status start now elapsed next_update output_file monitor_path monitored_bytes
  local monitor_marker current_file candidate detail
  local saved_int saved_term
  shift

  if ! dashboard_capable; then info "$label"; fi
  log_command "$@"
  if ! dashboard_capable; then
    printf '    Time left: unavailable\n'
    if "$@"; then
      return 0
    else
      status=$?
      printf '[FAILED] %s\n' "$label" >&2
      return "$status"
    fi
  fi

  output_file="$(mktemp "${TMPDIR:-/tmp}/resolve-command-output.XXXXXX")" || {
    run_with_visible_output "$label" "$@"
    return $?
  }
  start="$(date +%s)"
  monitor_path="${DAVINCI_PORTABLE_STATUS_MONITOR_PATH:-}"
  next_update=0
  current_file="${DAVINCI_PORTABLE_CURRENT_FILE:-}"
  detail="Elapsed 00:00"
  if [[ -n "$monitor_path" ]]; then
    monitor_marker="$(mktemp "${TMPDIR:-/tmp}/resolve-monitor-marker.XXXXXX")" || monitor_marker=""
  else
    monitor_marker=""
  fi
  RUN_STATUS_INTERRUPTED=0
  "$@" >"$output_file" 2>&1 &
  RUN_STATUS_PID=$!
  saved_int="$(trap -p INT || true)"
  saved_term="$(trap -p TERM || true)"
  trap _run_status_interrupt INT TERM
  ui_dashboard_set_indeterminate 'Progress   indeterminate' "$detail" "$current_file"
  ui_dashboard_begin || true
  while kill -0 "$RUN_STATUS_PID" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= next_update )); then
      detail="Elapsed $(format_duration "$elapsed")"
      if [[ -n "$monitor_path" ]]; then
        monitored_bytes="$(tree_size_bytes "$monitor_path" || true)"
        if [[ "$monitored_bytes" =~ ^[0-9]+$ ]]; then
          detail="Expanded $(human_bytes "$monitored_bytes")   Elapsed $(format_duration "$elapsed")"
        fi
        if [[ -n "$monitor_marker" && -d "$monitor_path" ]]; then
          while IFS= read -r -d '' candidate; do current_file="${candidate#"$monitor_path"/}"; break; done \
            < <(find "$monitor_path" -type f -newer "$monitor_marker" -print0 2>/dev/null)
          touch "$monitor_marker"
        fi
      fi
      next_update=$((elapsed + 2))
      ui_update_overall_eta 0
      ui_dashboard_set_indeterminate 'Progress   indeterminate' "$detail" "$current_file"
    fi
    ui_dashboard_render
    sleep 0.25
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
  ui_dashboard_end
  [[ -z "$monitor_marker" ]] || rm -f "$monitor_marker"
  if [[ -s "$output_file" ]]; then
    cat "$output_file"
  fi
  rm -f "$output_file"

  if [[ "$status" -ne 0 ]]; then
    printf '[FAILED] %s\n' "$label" >&2
  fi
  return "$status"
}

run_with_visible_output() {
  local label="$1" status
  shift
  info "$label..."
  log_command "$@"
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

format_duration() {
  local total="$1" hours minutes seconds
  [[ "$total" =~ ^[0-9]+$ ]] || return 1
  hours=$((total / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))
  if (( hours > 0 )); then
    printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
  else
    printf '%02d:%02d' "$minutes" "$seconds"
  fi
}

format_rate() {
  local bytes="$1" seconds="$2"
  [[ "$bytes" =~ ^[0-9]+$ && "$seconds" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s/s' "$(human_bytes "$((bytes / seconds))")"
}

estimated_eta() {
  local total="$1" completed="$2" elapsed="$3" remaining eta
  [[ "$total" =~ ^[0-9]+$ && "$completed" =~ ^[0-9]+$ && "$elapsed" =~ ^[0-9]+$ ]] || return 1
  if (( elapsed < 3 || completed == 0 )); then
    printf 'estimating...'
    return 0
  fi
  (( completed < total )) || { printf '00:00'; return 0; }
  remaining=$((total - completed))
  eta=$((remaining * elapsed / completed))
  format_duration "$eta"
}

log_copy_manifest() {
  local source="$1" prefix="$2" action="$3" item relative
  if verbose_output_enabled && ! dashboard_capable; then
    activity "$prefix" "$action" "$(basename "$source")"
    if [[ -d "$source" ]]; then
      while IFS= read -r -d '' item; do
        relative="${item#"$source"/}"
        activity "$prefix" "$action" "$relative"
      done < <(find "$source" -mindepth 1 -print0)
    fi
  fi
  return 0
}

copy_monitor_begin() {
  local source="$1" destination="$2" prefix="${3:-+}" action="${4:-copy}"
  COPY_MONITOR_SOURCE="$source"
  COPY_MONITOR_DESTINATION="$destination"
  COPY_MONITOR_PENDING=""
  COPY_MONITOR_COMPLETE=0
  COPY_MONITOR_PREFIX="$prefix"
  COPY_MONITOR_ACTION="$action"
  COPY_MONITOR_LIST="$(mktemp "${TMPDIR:-/tmp}/resolve-file-list.XXXXXX")" || return 1
  find "$source" -type f ! -name '._*' -print0 > "$COPY_MONITOR_LIST" || return 1
  exec 9< "$COPY_MONITOR_LIST"
}

copy_monitor_poll() {
  local candidate relative destination_candidate count=0 verbose_batch=0
  if verbose_output_enabled; then ui_dashboard_end; verbose_batch=1; fi
  while (( count < 50 )); do
    if [[ -n "$COPY_MONITOR_PENDING" ]]; then
      candidate="$COPY_MONITOR_PENDING"
    elif ! IFS= read -r -d '' candidate <&9; then
      COPY_MONITOR_COMPLETE=1
      break
    fi
    relative="${candidate#"$COPY_MONITOR_SOURCE"/}"
    destination_candidate="$COPY_MONITOR_DESTINATION/$relative"
    if [[ -f "$destination_candidate" ]]; then
      COPY_MONITOR_PENDING=""
      UI_DASHBOARD_CURRENT_FILE="$relative"
      if verbose_output_enabled; then
        activity "$COPY_MONITOR_PREFIX" "$COPY_MONITOR_ACTION" "$relative"
      fi
      count=$((count + 1))
    else
      COPY_MONITOR_PENDING="$candidate"
      break
    fi
  done
  if [[ "$verbose_batch" -eq 1 ]]; then ui_dashboard_begin || true; fi
  return 0
}

copy_monitor_end() {
  exec 9<&- 2>/dev/null || true
  [[ -z "$COPY_MONITOR_LIST" ]] || rm -f "$COPY_MONITOR_LIST"
  COPY_MONITOR_LIST=""
  COPY_MONITOR_PENDING=""
  COPY_MONITOR_COMPLETE=0
}

run_copy_with_progress() {
  local label="$1" source="$2" destination="$3" prefix="$4" action="$5"
  local total completed percent status start now elapsed rate eta next_update output_file
  local operation_name operation_start operation_end display_percent operation_eta_seconds completed_verb monitor_active
  local saved_int saved_term
  shift 5

  if ! dashboard_capable; then info "$label"; fi
  log_copy_manifest "$source" "$prefix" "$action"
  log_command "$@"
  total="$(tree_size_bytes "$source" || true)"
  if [[ ! "$total" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
    if ! dashboard_capable; then printf '    progress: indeterminate\n    Time left: unavailable\n'; fi
    if "$@"; then return 0; else
      status=$?
      printf '[FAILED] %s\n' "$label" >&2
      return "$status"
    fi
  fi

  if ! dashboard_capable; then
    printf '    %s: 0.0 B / %s   0%%\n' "$action" "$(human_bytes "$total")"
    printf '    Time left: estimating...\n'
    if "$@"; then
      printf '    %s: %s / %s   100%%\n' "$action" "$(human_bytes "$total")" "$(human_bytes "$total")"
      return 0
    else
      status=$?
      printf '[FAILED] %s\n' "$label" >&2
      return "$status"
    fi
  fi

  output_file="$(mktemp "${TMPDIR:-/tmp}/resolve-copy-output.XXXXXX")" || {
    run_with_visible_output "$label" "$@"
    return $?
  }
  case "$action" in
    backup) operation_name='Backup'; completed_verb='backed up' ;;
    restore) operation_name='Restore'; completed_verb='restored' ;;
    replace) operation_name='Replace'; completed_verb='replaced' ;;
    *) operation_name='Copy'; completed_verb='copied' ;;
  esac
  operation_start="$UI_OPERATION_BASE_PERCENT"
  (( operation_start >= PROGRESS_LAST_PERCENT )) || operation_start="$PROGRESS_LAST_PERCENT"
  operation_end="${DAVINCI_PORTABLE_OPERATION_END_PERCENT:-$operation_start}"
  [[ "$operation_end" =~ ^[0-9]+$ && "$operation_end" -ge "$operation_start" && "$operation_end" -le 100 ]] || \
    operation_end="$operation_start"
  start="$(date +%s)"
  next_update=0
  completed=0
  percent=0
  rate='estimating...'
  eta='estimating...'
  UI_DISPLAY_PERCENT="$operation_start"
  monitor_active=0
  if copy_monitor_begin "$source" "$destination" "$prefix" "$action"; then monitor_active=1; fi
  RUN_STATUS_INTERRUPTED=0
  "$@" >"$output_file" 2>&1 &
  RUN_STATUS_PID=$!
  saved_int="$(trap -p INT || true)"
  saved_term="$(trap -p TERM || true)"
  trap _run_status_interrupt INT TERM
  ui_dashboard_set_copy "$operation_name" 0 0 "$total" "$rate" "$eta" ''
  ui_dashboard_begin || true

  while kill -0 "$RUN_STATUS_PID" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start))
    [[ "$monitor_active" -eq 0 ]] || copy_monitor_poll
    if (( elapsed >= next_update )); then
      completed="$(tree_size_bytes "$destination" || true)"
      [[ "$completed" =~ ^[0-9]+$ ]] || completed=0
      (( completed <= total )) || completed="$total"
      if [[ "$COPY_MONITOR_COMPLETE" -eq 1 ]]; then completed="$total"; fi
      percent=$((completed * 100 / total))
      if (( elapsed < 3 || completed == 0 )); then
        rate='estimating...'
        eta='estimating...'
        operation_eta_seconds=0
      else
        rate="$(format_rate "$completed" "$elapsed")"
        eta="$(estimated_eta "$total" "$completed" "$elapsed")"
        if (( completed < total )); then
          operation_eta_seconds=$(((total - completed) * elapsed / completed))
        else
          operation_eta_seconds=0
        fi
      fi
      display_percent=$((operation_start + (operation_end - operation_start) * percent / 100))
      UI_DISPLAY_PERCENT="$display_percent"
      ui_update_overall_eta "$operation_eta_seconds"
      ui_dashboard_set_copy "$operation_name" "$percent" "$completed" "$total" "$rate" "$eta" \
        "$UI_DASHBOARD_CURRENT_FILE"
      next_update=$((elapsed + 1))
    fi
    ui_dashboard_render
    sleep 0.25
  done

  if wait "$RUN_STATUS_PID"; then status=0; else status=$?; fi
  [[ "$RUN_STATUS_INTERRUPTED" -eq 0 ]] || status=130
  RUN_STATUS_PID=""
  if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
  if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
  ui_dashboard_end
  [[ "$monitor_active" -eq 0 ]] || copy_monitor_end
  unset UI_DISPLAY_PERCENT
  if [[ -s "$output_file" ]]; then cat "$output_file"; fi
  rm -f "$output_file"

  if [[ "$status" -eq 0 ]]; then
    UI_OPERATION_BASE_PERCENT="$operation_end"
    completed_action "$completed_verb" "$(basename "$destination")"
  else
    printf '[FAILED] %s\n' "$label" >&2
  fi
  return "$status"
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

report_resolve_validation() {
  validation_ok "Resolve executable signature"
  validation_ok "embedded redirect dylib"
  validation_ok "redirect dylib signature"
  validation_ok "redirect dylib architecture: arm64"
  validation_ok "allow-dyld-environment-variables"
  validation_ok "disable-library-validation"
}

portable_root_from_script() {
  local script_dir="$1"
  if [[ "$script_dir" == */"$STATE_RELATIVE/bin" ]]; then
    dirname "$(dirname "$script_dir")"
  else
    return 1
  fi
}
