#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
else
  PROJECT_DIR="$SCRIPT_DIR"
fi
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/update_helpers.sh"

INSTALL_WORK_DIR=""
INCOMING_PATH=""
SUPPORT_TRANSACTION_ACTIVE=0
SUPPORT_TRANSACTION_ROOT=""
SUPPORT_BACKUP_DIR=""
SUPPORT_ITEMS=()
SUPPORT_EXISTED=()
UPDATE_TRANSACTION_ACTIVE=0
UPDATE_TRANSACTION_ROOT=""
UPDATE_ROLLBACK_DIR=""
UPDATE_NEW_APP=""
restore_support_transaction() {
  local index item
  [[ "$SUPPORT_TRANSACTION_ACTIVE" -eq 1 ]] || return 0
  section "Rolling back support files"
  for ((index=0; index<${#SUPPORT_ITEMS[@]}; index++)); do
    item="${SUPPORT_ITEMS[$index]}"
    activity '-' 'remove' "$item"
    rm -rf "$SUPPORT_TRANSACTION_ROOT/$item"
    if [[ "${SUPPORT_EXISTED[$index]}" -eq 1 ]]; then
      run_with_status "Restoring support payload: $item" \
        ditto "$SUPPORT_BACKUP_DIR/$item" "$SUPPORT_TRANSACTION_ROOT/$item"
    fi
  done
  SUPPORT_TRANSACTION_ACTIVE=0
}
cleanup_install_work() {
  if [[ "$UPDATE_TRANSACTION_ACTIVE" -eq 1 ]]; then
    printf '\nUpdate failed.\n\nRestoring previous installation...\n' >&2
    if restore_update_rollback "$UPDATE_TRANSACTION_ROOT" "$UPDATE_ROLLBACK_DIR" "$UPDATE_NEW_APP"; then
      printf 'Previous installation restored successfully.\n' >&2
    else
      printf 'Automatic rollback failed.\nRollback data retained:\n%s\n' \
        "$UPDATE_ROLLBACK_DIR" >&2
    fi
    UPDATE_TRANSACTION_ACTIVE=0
  fi
  restore_support_transaction
  if [[ -n "$INCOMING_PATH" && -e "$INCOMING_PATH" ]]; then
    rm -rf "$INCOMING_PATH"
  fi
  if [[ -n "$INSTALL_WORK_DIR" && -d "$INSTALL_WORK_DIR" ]]; then
    rm -rf "$INSTALL_WORK_DIR"
  fi
}

install_from_pkg() {
  local mode="$1" pkg="$2" portable_root="$3"
  local support apps state work expanded extracted_app version app_name staged_app
  local destination_app incoming rollback icon executable entitlements timestamp launcher
  local payload payload_item payload_name source_file asset_scripts source_c
  local prior_app candidate_prior failed support_backup_seen index
  local source_executable signature_details resigned_signature_details runtime_option package_bytes preflight_bytes
  local expanded_bytes local_copy_bytes launcher_id
  local user_application_support_path user_preferences_path
  local installed_version installed_app support_items rollback_dir transition old_version
  local guided_progress launcher_phase support_phase payload_action

  [[ "$mode" == "build" || "$mode" == "update" ]] || die "Internal mode error."
  guided_progress=0
  if [[ "$mode" == "update" && "$PROGRESS_LAST_PERCENT" -ge 10 ]]; then
    guided_progress=1
  else
    progress_reset
    progress_phase 5 "Preflight"
  fi
  [[ -f "$pkg" && "$pkg" == *.pkg ]] || die "Select an official DaVinci Resolve .pkg file."
  ensure_portable_root "$portable_root"
  portable_root="$(canonical_existing_dir "$portable_root")"
  support="$portable_root/$SUPPORT_RELATIVE"
  apps="$portable_root/$APPS_RELATIVE"
  state="$portable_root/$STATE_RELATIVE"
  launcher="$apps/$LAUNCHER_NAME"
  user_application_support_path="$(portable_user_application_support_path)"
  user_preferences_path="$(portable_user_preferences_path)"

  [[ "$guided_progress" -eq 1 ]] || progress_phase 10 "Checking paths"
  if [[ "$mode" == "build" ]] && managed_portable_root_exists "$portable_root"; then
    die "An existing portable installation was found. Use Update Portable Resolve.command instead."
  fi
  if [[ "$mode" == "update" ]] && ! managed_portable_root_exists "$portable_root"; then
    die "No project-managed portable installation was found at this root. Use Build Portable Resolve.command for a new installation."
  fi
  installed_version=""
  installed_app=""
  if [[ "$mode" == "update" ]]; then
    validate_managed_installation "$portable_root" || \
      die "The current project-managed installation is invalid. Run diagnostics before updating."
    installed_version="$(current_install_version "$portable_root")"
    installed_app="$(current_install_app "$portable_root")"
    if [[ "$guided_progress" -eq 0 ]]; then
      section "Current installation"
      printf 'Version: %s\nApp:     %s\n' "$installed_version" "$installed_app"
    fi
  fi

  if [[ -e "$launcher" || -L "$launcher" ]]; then
    launcher_id="$(plist_value "$launcher/Contents/Info.plist" CFBundleIdentifier || true)"
    [[ "$launcher_id" == "io.github.MES30004E.davinci-resolve-portable" ]] || \
      die "The launcher destination already contains an app not owned by this project: $launcher"
  fi

  preflight_user_symlink "$user_application_support_path" "$support/User" "Application Support"
  preflight_user_symlink "$user_preferences_path" "$support/User Preferences" "Preferences"

  require_macos
  for tool in pkgutil ditto codesign plutil xcrun lipo; do require_command "$tool"; done
  [[ "$(uname -m)" == "arm64" ]] || die "Only Apple Silicon (arm64) is currently supported."

  section "Installer"
  printf 'Package: %s\n' "$pkg"
  progress_phase 15 "Checking installer signature"
  if ! run_with_visible_output "Verifying installer signature" pkgutil --check-signature "$pkg"; then
    die "pkgutil could not validate the selected package signature. The package was not extracted."
  fi
  validation_ok "package signature accepted by pkgutil"

  progress_phase 20 "Checking disk space"
  package_bytes="$(file_size_bytes "$pkg" || true)"
  if [[ "$package_bytes" =~ ^[0-9]+$ ]]; then
    # Allow roughly 3x compressed package size plus 1 GiB for expansion/copies.
    preflight_bytes="$((package_bytes * 3 + 1073741824))"
    require_free_space "local staging filesystem" "${TMPDIR:-/tmp}" "$preflight_bytes"
    require_free_space "portable destination filesystem" "$portable_root" "$preflight_bytes"
    validation_ok "free space checked"
  else
    warn "Could not determine installer size; continuing with post-expansion space checks."
  fi

  progress_phase 25 "Preparing staging area"
  work="$(mktemp -d "${TMPDIR:-/tmp}/resolve-portable.XXXXXX")"
  INSTALL_WORK_DIR="$work"
  trap cleanup_install_work EXIT
  expanded="$work/expanded"
  section "Expanding installer"
  progress_phase 40 "Expanding installer"
  activity '+' 'extract' "$(basename "$pkg")"
  DAVINCI_PORTABLE_STATUS_MONITOR_PATH="$expanded" \
    run_with_status "Expanding installer" pkgutil --expand-full "$pkg" "$expanded" || \
    die "Could not expand the selected installer."
  progress_phase 45 "Discovering Resolve payload"
  extracted_app="$(find_resolve_app "$expanded" || true)"
  [[ -n "$extracted_app" ]] || die "Could not locate DaVinci Resolve.app in the expanded package."
  progress_phase 50 "Detecting Resolve version"
  version="$(resolve_version "$extracted_app" || true)"
  [[ -n "$version" ]] || die "The extracted app has no CFBundleShortVersionString."
  [[ "$version" != */* && "$version" != *$'\n'* ]] || die "Unsafe Resolve version value: $version"
  info "Found DaVinci Resolve $version."
  if [[ "$mode" == "update" ]]; then
    section "Incoming installer"
    printf 'Version: %s\n' "$version"
    confirm_version_transition "$installed_version" "$version" || \
      die "Update cancelled. The existing installation was not modified."
  fi

  expanded_bytes="$(tree_size_bytes "$expanded" || true)"
  if [[ "$expanded_bytes" =~ ^[0-9]+$ ]]; then
    local_copy_bytes="$((expanded_bytes + 536870912))"
    require_free_space "local staging filesystem after expansion" "$work" "$local_copy_bytes"
    require_free_space "portable destination filesystem" "$portable_root" "$local_copy_bytes"
  else
    warn "Could not estimate expanded package size."
  fi

  app_name="DaVinci Resolve $version.app"
  destination_app="$support/$app_name"
  if [[ "$mode" == "update" && -e "$destination_app" && "$destination_app" != "$installed_app" ]]; then
    die "A non-current app already exists at the update destination: $destination_app"
  fi
  staged_app="$work/$app_name"
  section "Preparing Resolve $version"
  progress_phase 60 "Preparing Resolve $version"
  DAVINCI_PORTABLE_OPERATION_END_PERCENT=70 \
    run_copy_with_progress "Copying Resolve to local staging" "$extracted_app" "$staged_app" '+' copy \
    ditto --rsrc --extattr "$extracted_app" "$staged_app" || \
    die "Could not copy Resolve into local staging."
  icon="$extracted_app/Contents/Resources/Resolve.icns"
  [[ -f "$icon" ]] || die "The official app does not contain Contents/Resources/Resolve.icns."

  progress_phase 70 "Building redirect library"
  mkdir -p "$staged_app/Contents/Frameworks"
  activity '+' 'embed' "Contents/Frameworks/$DYLIB_NAME"
  if ! DAVINCI_PORTABLE_CURRENT_FILE="Contents/Frameworks/$DYLIB_NAME" \
    run_with_visible_output "Building redirect library" \
    "$SCRIPT_DIR/build_redirect.sh" "$support" "$staged_app/Contents/Frameworks/$DYLIB_NAME"; then
    die "Could not build the redirect library."
  fi
  validation_ok "redirect dylib built for arm64"

  progress_phase 78 "Signing Resolve"
  source_executable="$extracted_app/Contents/MacOS/Resolve"
  signature_details="$(codesign -dvv "$source_executable" 2>&1 || true)"
  runtime_option="$(runtime_signing_option "$signature_details")"
  if [[ -n "$runtime_option" ]]; then
    validation_ok "Hardened Runtime detected and preserved"
  else
    validation_ok "source does not use Hardened Runtime"
  fi

  executable="$staged_app/Contents/MacOS/Resolve"
  entitlements="$work/resolve-entitlements.plist"
  if ! codesign -d --entitlements :- "$executable" >"$entitlements" 2>/dev/null || ! plutil -lint "$entitlements" >/dev/null 2>&1; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict/></plist>' > "$entitlements"
  fi
  for entitlement in \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-dyld-environment-variables
  do
    /usr/libexec/PlistBuddy -c "Set :$entitlement true" "$entitlements" >/dev/null 2>&1 || \
      /usr/libexec/PlistBuddy -c "Add :$entitlement bool true" "$entitlements"
  done
  plutil -lint "$entitlements" >/dev/null
  validation_ok "original entitlements read"
  activity '~' 'sign' "Contents/MacOS/Resolve"
  if [[ -n "$runtime_option" ]]; then
    DAVINCI_PORTABLE_CURRENT_FILE='Contents/MacOS/Resolve' run_with_status "Signing Resolve executable" \
      codesign --force --sign - --options runtime --entitlements "$entitlements" "$executable" || \
      die "Could not sign the Resolve executable."
  else
    DAVINCI_PORTABLE_CURRENT_FILE='Contents/MacOS/Resolve' run_with_status "Signing Resolve executable" \
      codesign --force --sign - --entitlements "$entitlements" "$executable" || \
      die "Could not sign the Resolve executable."
  fi
  DAVINCI_PORTABLE_CURRENT_FILE='Contents/MacOS/Resolve' run_with_status "Verifying Resolve executable signature" \
    codesign --verify --strict "$executable" || \
    die "The re-signed Resolve executable signature did not validate."
  validation_ok "Resolve executable signature"
  resigned_signature_details="$(codesign -dvv "$executable" 2>&1 || true)"
  if [[ -n "$runtime_option" ]]; then
    code_signature_has_runtime "$resigned_signature_details" || \
      die "The re-signed Resolve executable did not retain Hardened Runtime."
  elif code_signature_has_runtime "$resigned_signature_details"; then
    die "The re-signed Resolve executable unexpectedly gained Hardened Runtime."
  fi
  codesign -d --entitlements :- "$executable" 2>/dev/null | plutil -lint - >/dev/null
  validation_ok "required Resolve entitlements"

  mkdir -p "$support" "$apps" "$state/rollback"
  mkdir -p "$support/User" "$support/User Preferences"

  progress_phase 84 "Installing and validating Resolve"
  section "Installing application"
  incoming="$support/.$app_name.incoming.$$"
  INCOMING_PATH="$incoming"
  if [[ -e "$incoming" ]]; then
    activity '-' 'remove' "$(basename "$incoming")"
    rm -rf "$incoming"
  fi
  printf 'From: local staging\nTo:   %s\n' "$destination_app"
  DAVINCI_PORTABLE_OPERATION_END_PERCENT=88 \
    run_copy_with_progress "Copying Resolve to the portable destination" "$staged_app" "$incoming" '+' copy \
    ditto --rsrc --extattr "$staged_app" "$incoming" || \
    die "Could not copy Resolve to the portable destination."
  if ! run_with_status "Validating staged Resolve" validate_resolve_app "$incoming"; then
    die "The staged app failed validation after copying to the portable drive."
  fi
  report_resolve_validation

  # Copy package support payloads without assuming a component-package hierarchy.
  if [[ "$mode" == "update" ]]; then
    section "Backup"
    progress_phase 88 "Preparing support payload"
    support_items="$work/support-items"
    mkdir -p "$support_items"
    while IFS= read -r -d '' payload; do
      while IFS= read -r -d '' payload_item; do
        payload_name="$(basename "$payload_item")"
        case "$payload_name" in
          User|'User Preferences') ;;
          *) safe_support_item_name "$payload_name" || die "Unsafe support payload name: $payload_name"
             mkdir -p "$support_items/$payload_name" ;;
        esac
      done < <(find "$payload" -mindepth 1 -maxdepth 1 -print0)
    done < <(find_support_payloads "$expanded")

    progress_phase 90 "Creating rollback backup"
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    rollback_dir="$state/rollback/update-$timestamp"
    create_update_rollback "$portable_root" "$installed_app" "$launcher" \
      "$support_items" "$rollback_dir" || die "Could not create the update rollback backup."
    UPDATE_TRANSACTION_ROOT="$portable_root"
    UPDATE_ROLLBACK_DIR="$rollback_dir"
    UPDATE_NEW_APP="$support/$app_name"
    UPDATE_TRANSACTION_ACTIVE=1
    printf 'Rollback: %s\n' "$rollback_dir"
    activity '=' 'preserve' 'User/'
    activity '=' 'preserve' 'User Preferences/'
    support_phase="Updating support payload"
  else
    progress_phase 90 "Installing support payload"
    support_phase="Installing support payload"
  fi
  section "Support files"
  activity '=' 'preserve' 'User/'
  activity '=' 'preserve' 'User Preferences/'
  progress_phase 92 "$support_phase"
  while IFS= read -r -d '' payload; do
    while IFS= read -r -d '' payload_item; do
      payload_name="$(basename "$payload_item")"
      case "$payload_name" in
        User|'User Preferences')
          activity '=' 'preserve' "$payload_name/"
          ;;
        *)
          if [[ -e "$support/$payload_name" || -L "$support/$payload_name" ]]; then
            payload_action='replaced'
            log_copy_manifest "$payload_item" '~' replace
          else
            payload_action='copied'
            log_copy_manifest "$payload_item" '+' copy
          fi
          run_with_status "Installing support payload: $payload_name" \
            ditto "$payload_item" "$support/$payload_name" || \
            die "Could not install support payload: $payload_name"
          completed_action "$payload_action" "$payload_name"
          ;;
      esac
    done < <(find "$payload" -mindepth 1 -maxdepth 1 -print0)
  done < <(find_support_payloads "$expanded")

  rollback=""
  prior_app="$installed_app"
  if [[ "$mode" != "update" && -f "$state/current-app" ]]; then
    candidate_prior="$(sed -n '1p' "$state/current-app")"
    case "$candidate_prior" in
      "$support"/DaVinci\ Resolve\ *.app)
        [[ -d "$candidate_prior" ]] && prior_app="$candidate_prior"
        ;;
    esac
  fi
  if [[ -e "$destination_app" && "$destination_app" != "$prior_app" ]]; then
    die "A non-current app already exists at the destination: $destination_app
It was left untouched. Move or inspect it before retrying."
  fi
  if [[ "$mode" == "update" && -n "$prior_app" ]]; then
    activity '-' 'remove' "$(basename "$prior_app")"
    rm -rf "$prior_app"
  elif [[ -n "$prior_app" ]]; then
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    rollback="$state/rollback/$(basename "$prior_app").$timestamp"
    activity '>' 'backup' "$(basename "$prior_app")"
    mv "$prior_app" "$rollback"
  fi
  activity '~' 'activate' "$app_name"
  if ! mv "$incoming" "$destination_app"; then
    [[ "$mode" != "update" && -n "$rollback" && -e "$rollback" ]] && mv "$rollback" "$prior_app"
    die "Could not activate the staged app; the prior same-version app was restored."
  fi
  INCOMING_PATH=""
  if ! run_with_status "Validating activated Resolve" validate_resolve_app "$destination_app"; then
    if [[ "$mode" == "update" ]]; then
      die "Post-install validation failed; automatic rollback will be attempted."
    else
      failed="$state/failed-$app_name.$$"
      mv "$destination_app" "$failed"
      [[ -n "$rollback" && -e "$rollback" ]] && mv "$rollback" "$prior_app"
      die "Post-install validation failed. Failed copy: $failed"
    fi
  fi
  report_resolve_validation

  [[ "$mode" == "update" ]] && launcher_phase="Rebuilding launcher" || launcher_phase="Creating launcher"
  section "Launcher"
  progress_phase 96 "$launcher_phase"
  if [[ -e "$launcher" ]]; then
    activity '~' 'replace' "$APPS_RELATIVE/$LAUNCHER_NAME"
  else
    activity '+' 'create' "$APPS_RELATIVE/$LAUNCHER_NAME"
  fi
  if ! run_with_status "$launcher_phase" \
    "$SCRIPT_DIR/build_launcher.sh" "$destination_app" "$launcher" "$icon"; then
    if [[ "$mode" == "update" ]]; then
      die "Launcher generation failed; automatic rollback will be attempted."
    else
      failed="$state/failed-$app_name.$$"
      mv "$destination_app" "$failed"
      [[ -n "$rollback" && -e "$rollback" ]] && mv "$rollback" "$prior_app"
      die "Launcher generation failed. Failed copy: $failed"
    fi
  fi
  validation_ok "launcher generated"
  activity '~' 'update' "$STATE_RELATIVE/portable-root"
  printf '%s\n' "$portable_root" > "$state/portable-root"
  activity '~' 'update' "$STATE_RELATIVE/current-app"
  printf '%s\n' "$destination_app" > "$state/current-app"
  activity '~' 'update' "$STATE_RELATIVE/version"
  printf '%s\n' "$version" > "$state/version"
  SUPPORT_TRANSACTION_ACTIVE=0
  mkdir -p "$state/bin"
  for file in 'Update Portable Resolve.command' 'Uninstall.command'; do
    source_file="$PROJECT_DIR/$file"
    [[ -f "$source_file" ]] || source_file="$SCRIPT_DIR/$file"
    copy_project_runtime_file "$source_file" "$state/bin/$file" "$file" || \
      die "Could not refresh project runtime helper: $file"
    chmod +x "$state/bin/$file"
  done
  asset_scripts="$PROJECT_DIR/scripts"
  [[ -d "$asset_scripts" ]] || asset_scripts="$SCRIPT_DIR"
  for file in diagnose.command common.sh install_core.sh build_redirect.sh build_launcher.sh update_helpers.sh; do
    copy_project_runtime_file "$asset_scripts/$file" "$state/bin/$file" "$file" || \
      die "Could not refresh project runtime helper: $file"
  done
  mkdir -p "$state/src"
  source_c="$PROJECT_DIR/src/resolve_redirect.c"
  [[ -f "$source_c" ]] || source_c="$PROJECT_DIR/../src/resolve_redirect.c"
  copy_project_runtime_file "$source_c" "$state/src/resolve_redirect.c" resolve_redirect.c || \
    die "Could not refresh project runtime source: resolve_redirect.c"

  # Make user-Library changes only after the portable install and launcher are ready.
  progress_phase 97 "Validating user symlinks"
  prepare_user_symlink "$user_application_support_path" "$support/User" "Application Support"
  prepare_user_symlink "$user_preferences_path" "$support/User Preferences" "Preferences"
  validation_ok "user symlinks"

  if [[ "$mode" == "update" ]]; then
    section "Validation"
    progress_phase 98 "Validating updated installation"
    run_with_status "Validating updated installation" \
      validate_managed_installation "$portable_root" || \
      die "The updated installation failed final validation."
    UPDATE_TRANSACTION_ACTIVE=0
    progress_phase 100 "Update complete"
    printf '\nUpdate complete\n\n%s -> %s\n\nRollback backup retained:\n%s\n' \
      "$installed_version" "$version" "$rollback_dir"
    if confirm 'Delete rollback backup now?'; then
      case "$rollback_dir" in
        "$state/rollback/update-"*) activity '-' 'remove' "$rollback_dir"; rm -rf "$rollback_dir" ;;
      esac
    fi
  else
    section "Complete"
    progress_phase 100 "Portable Resolve ready"
  fi
  info "Portable DaVinci Resolve $version is ready."
  info "Launcher: $launcher"
  [[ "$mode" != "update" && -n "$rollback" ]] && info "Rollback retained at: $rollback"
  info "The first launch may ask for removable-volume access; choose Allow."
}
