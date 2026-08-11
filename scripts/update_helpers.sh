#!/bin/bash

# Guided-updater helpers. common.sh must be sourced first.

current_install_app() {
  local root="$1" state="$1/$STATE_RELATIVE" app
  [[ -f "$state/current-app" ]] || return 1
  app="$(sed -n '1p' "$state/current-app")"
  [[ -n "$app" && "$app" != *$'\n'* ]] || return 1
  case "$app" in
    "$root/$SUPPORT_RELATIVE"/DaVinci\ Resolve\ *.app) ;;
    *) return 1 ;;
  esac
  [[ -d "$app" ]] || return 1
  printf '%s\n' "$app"
}

current_install_version() {
  local root="$1" version_file="$1/$STATE_RELATIVE/version" version
  [[ -f "$version_file" ]] || return 1
  version="$(sed -n '1p' "$version_file")"
  [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
  printf '%s\n' "$version"
}

validate_managed_installation() {
  local root="$1" canonical app state_version app_version launcher launcher_id
  [[ -d "$root" ]] || return 1
  canonical="$(canonical_existing_dir "$root" || true)"
  [[ -n "$canonical" && "$canonical" == "$root" ]] || return 1
  managed_portable_root_exists "$root" || return 1
  app="$(current_install_app "$root" || true)"
  state_version="$(current_install_version "$root" || true)"
  [[ -n "$app" && -n "$state_version" ]] || return 1
  app_version="$(resolve_version "$app" || true)"
  [[ "$app_version" == "$state_version" ]] || return 1
  launcher="$root/$APPS_RELATIVE/$LAUNCHER_NAME"
  [[ -f "$launcher/Contents/Info.plist" ]] || return 1
  launcher_id="$(plist_value "$launcher/Contents/Info.plist" CFBundleIdentifier || true)"
  [[ "$launcher_id" == 'io.github.MES30004E.davinci-resolve-portable' ]] || return 1
  validate_resolve_app "$app"
}

discover_managed_installations() {
  local scan_root="${1:-${DAVINCI_PORTABLE_VOLUMES_ROOT:-/Volumes}}"
  local volume candidate
  [[ -d "$scan_root" ]] || return 0
  while IFS= read -r -d '' volume; do
    if validate_managed_installation "$volume"; then
      printf '%s\0' "$volume"
    fi
    while IFS= read -r -d '' candidate; do
      if validate_managed_installation "$candidate"; then
        printf '%s\0' "$candidate"
      fi
    done < <(find "$volume" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  done < <(find "$scan_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

select_managed_installation() {
  local scan_root="${1:-${DAVINCI_PORTABLE_VOLUMES_ROOT:-/Volumes}}"
  local candidates=() candidate selection manual
  while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done \
    < <(discover_managed_installations "$scan_root")

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    printf 'Portable Resolve installation found:\n%s\n' "${candidates[0]}" >&2
    printf '%s\n' "${candidates[0]}"
    return 0
  fi
  if [[ "${#candidates[@]}" -gt 1 ]]; then
    printf 'Found multiple portable Resolve installations:\n\n' >&2
    for ((selection=0; selection<${#candidates[@]}; selection++)); do
      printf '%d. %s\n' "$((selection + 1))" "${candidates[$selection]}" >&2
    done
    while true; do
      printf '\nChoose installation [1-%d]: ' "${#candidates[@]}" >&2
      IFS= read -r selection
      if [[ "$selection" =~ ^[0-9]+$ ]] && \
         (( selection >= 1 && selection <= ${#candidates[@]} )); then
        printf '%s\n' "${candidates[$((selection - 1))]}"
        return 0
      fi
      warn "Choose a number from 1 to ${#candidates[@]}."
    done
  fi

  manual="$(prompt_path $'No project-managed portable installation was auto-detected.\nDrag or paste the portable root here, then press Return: ')"
  ensure_portable_root "$manual"
  manual="$(canonical_existing_dir "$manual")"
  validate_managed_installation "$manual" || \
    die "The selected root is not a valid project-managed portable installation."
  printf '%s\n' "$manual"
}

version_compare() {
  local left="$1" right="$2" left_parts right_parts length position left_value right_value
  [[ "$left" =~ ^[0-9]+([.][0-9]+)*$ && "$right" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 2
  IFS='.' read -r -a left_parts <<<"$left"
  IFS='.' read -r -a right_parts <<<"$right"
  length="${#left_parts[@]}"
  (( ${#right_parts[@]} > length )) && length="${#right_parts[@]}"
  for ((position=0; position<length; position++)); do
    left_value="${left_parts[$position]:-0}"
    right_value="${right_parts[$position]:-0}"
    left_value=$((10#$left_value))
    right_value=$((10#$right_value))
    if (( left_value < right_value )); then printf '%s\n' -1; return 0; fi
    if (( left_value > right_value )); then printf '%s\n' 1; return 0; fi
  done
  printf '%s\n' 0
}

confirm_version_transition() {
  local installed="$1" incoming="$2" comparison
  comparison="$(version_compare "$installed" "$incoming")" || return 1
  if [[ "$comparison" -lt 0 ]]; then return 0; fi
  if [[ "$comparison" -eq 0 ]]; then
    printf 'This version is already installed.\n' >&2
    confirm 'Perform a repair/reinstall?'
  else
    printf 'The selected installer is older than the installed version.\n' >&2
    confirm 'Perform a downgrade?'
  fi
}

safe_support_item_name() {
  local name="$1"
  [[ -n "$name" && "$name" != '.' && "$name" != '..' ]] || return 1
  [[ "$name" != */* && "$name" != *$'\n'* && "$name" != *$'\t'* ]] || return 1
  [[ "$name" != 'User' && "$name" != 'User Preferences' ]]
}

create_update_rollback() {
  local root="$1" current_app="$2" launcher="$3" staged_support="$4" rollback="$5"
  local state="$root/$STATE_RELATIVE" support="$root/$SUPPORT_RELATIVE" item name
  [[ ! -e "$rollback" && "$rollback" == "$state/rollback/update-"* ]] || return 1
  current_install_app "$root" >/dev/null || return 1
  [[ "$current_app" == "$(current_install_app "$root")" ]] || return 1
  mkdir -p "$rollback/app" "$rollback/state" "$rollback/support"
  printf 'Creating rollback backup:\n%s\n' "$rollback"
  activity '=' 'preserve' 'User/'
  activity '=' 'preserve' 'User Preferences/'
  DAVINCI_PORTABLE_OPERATION_END_PERCENT=91 \
    run_copy_with_progress "Backing up current Resolve application" "$current_app" \
    "$rollback/app/$(basename "$current_app")" '>' backup \
    ditto "$current_app" "$rollback/app/$(basename "$current_app")" || return 1
  printf '%s\n' "$current_app" > "$rollback/previous-app-path"
  for name in portable-root current-app version; do
    activity '>' 'backup' "state/$name"
    log_command cp "$state/$name" "$rollback/state/$name"
    cp "$state/$name" "$rollback/state/$name" || return 1
  done
  for name in bin src; do
    [[ ! -e "$state/$name" ]] || {
      log_copy_manifest "$state/$name" '>' backup
      run_with_status "Backing up project runtime: $name" \
        ditto "$state/$name" "$rollback/state/$name" || return 1
      completed_action 'backed up' "state/$name"
    } || return 1
  done
  if [[ -d "$launcher" ]]; then
    mkdir -p "$rollback/launcher"
    log_copy_manifest "$launcher" '>' backup
    run_with_status "Backing up launcher" \
      ditto "$launcher" "$rollback/launcher/$LAUNCHER_NAME" || return 1
    completed_action 'backed up' "launcher/$LAUNCHER_NAME"
    printf 'existing\n' > "$rollback/launcher-state"
  else
    printf 'missing\n' > "$rollback/launcher-state"
  fi
  : > "$rollback/support-manifest"
  if [[ -d "$staged_support" ]]; then
    while IFS= read -r -d '' item; do
      name="$(basename "$item")"
      safe_support_item_name "$name" || return 1
      if [[ -e "$support/$name" || -L "$support/$name" ]]; then
        DAVINCI_PORTABLE_OPERATION_END_PERCENT=92 \
          run_copy_with_progress "Backing up support payload: $name" "$support/$name" \
          "$rollback/support/$name" '>' backup \
          ditto "$support/$name" "$rollback/support/$name" || return 1
        printf 'existing\t%s\n' "$name" >> "$rollback/support-manifest"
      else
        printf 'missing\t%s\n' "$name" >> "$rollback/support-manifest"
      fi
    done < <(find "$staged_support" -mindepth 1 -maxdepth 1 -print0)
  fi
}

restore_update_rollback() {
  local root="$1" rollback="$2" new_app="$3"
  local state="$root/$STATE_RELATIVE" support="$root/$SUPPORT_RELATIVE"
  local launcher="$root/$APPS_RELATIVE/$LAUNCHER_NAME" previous_app status kind name
  status=0
  [[ "$rollback" == "$state/rollback/update-"* && -d "$rollback" ]] || return 1
  previous_app="$(sed -n '1p' "$rollback/previous-app-path" 2>/dev/null || true)"
  case "$previous_app" in "$support"/DaVinci\ Resolve\ *.app) ;; *) return 1 ;; esac
  case "$new_app" in "$support"/DaVinci\ Resolve\ *.app) ;; *) return 1 ;; esac

  section "Rolling back"
  if [[ -e "$new_app" ]]; then activity '-' 'remove' "$(basename "$new_app")"; rm -rf "$new_app" || status=1; fi
  if [[ "$previous_app" != "$new_app" && -e "$previous_app" ]]; then
    activity '-' 'remove' "$(basename "$previous_app")"
    rm -rf "$previous_app" || status=1
  fi
  run_copy_with_progress "Restoring previous Resolve application" \
    "$rollback/app/$(basename "$previous_app")" "$previous_app" '<' restore \
    ditto "$rollback/app/$(basename "$previous_app")" "$previous_app" || status=1

  while IFS=$'\t' read -r kind name; do
    [[ -n "$name" ]] || continue
    safe_support_item_name "$name" || { status=1; continue; }
    if [[ -e "$support/$name" || -L "$support/$name" ]]; then
      activity '-' 'remove' "support/$name"
      rm -rf "$support/$name" || status=1
    fi
    if [[ "$kind" == 'existing' ]]; then
      run_copy_with_progress "Restoring support payload: $name" "$rollback/support/$name" \
        "$support/$name" '<' restore \
        ditto "$rollback/support/$name" "$support/$name" || status=1
    elif [[ "$kind" != 'missing' ]]; then
      status=1
    fi
  done < "$rollback/support-manifest"

  if [[ -e "$launcher" ]]; then activity '-' 'remove' "launcher/$LAUNCHER_NAME"; rm -rf "$launcher" || status=1; fi
  if [[ "$(sed -n '1p' "$rollback/launcher-state" 2>/dev/null)" == 'existing' ]]; then
    log_copy_manifest "$rollback/launcher/$LAUNCHER_NAME" '<' restore
    run_with_status "Restoring launcher" \
      ditto "$rollback/launcher/$LAUNCHER_NAME" "$launcher" || status=1
    [[ "$status" -ne 0 ]] || completed_action restored "launcher/$LAUNCHER_NAME"
  fi
  for name in portable-root current-app version; do
    activity '<' 'restore' "state/$name"
    cp "$rollback/state/$name" "$state/$name" || status=1
  done
  for name in bin src; do
    if [[ -e "$state/$name" ]]; then activity '-' 'remove' "state/$name"; rm -rf "$state/$name" || status=1; fi
    [[ ! -e "$rollback/state/$name" ]] || {
      log_copy_manifest "$rollback/state/$name" '<' restore
      run_with_status "Restoring project runtime: $name" \
        ditto "$rollback/state/$name" "$state/$name"
    } || status=1
  done
  [[ "$status" -eq 0 ]] || return 1
  validate_managed_installation "$root" || return 1
  validation_ok "restored installation"
}
