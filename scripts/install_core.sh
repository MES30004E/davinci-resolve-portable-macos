#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
else
  PROJECT_DIR="$SCRIPT_DIR"
fi
source "$SCRIPT_DIR/common.sh"

INSTALL_WORK_DIR=""
INCOMING_PATH=""
SUPPORT_TRANSACTION_ACTIVE=0
SUPPORT_TRANSACTION_ROOT=""
SUPPORT_BACKUP_DIR=""
SUPPORT_ITEMS=()
SUPPORT_EXISTED=()
restore_support_transaction() {
  local index item
  [[ "$SUPPORT_TRANSACTION_ACTIVE" -eq 1 ]] || return 0
  warn "Restoring support payload from the update rollback..."
  for ((index=0; index<${#SUPPORT_ITEMS[@]}; index++)); do
    item="${SUPPORT_ITEMS[$index]}"
    rm -rf "$SUPPORT_TRANSACTION_ROOT/$item"
    if [[ "${SUPPORT_EXISTED[$index]}" -eq 1 ]]; then
      ditto "$SUPPORT_BACKUP_DIR/$item" "$SUPPORT_TRANSACTION_ROOT/$item"
    fi
  done
  SUPPORT_TRANSACTION_ACTIVE=0
}
cleanup_install_work() {
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

  [[ "$mode" == "build" || "$mode" == "update" ]] || die "Internal mode error."
  progress_reset
  progress_phase 5 "Preflight"
  [[ -f "$pkg" && "$pkg" == *.pkg ]] || die "Select an official DaVinci Resolve .pkg file."
  ensure_portable_root "$portable_root"
  portable_root="$(canonical_existing_dir "$portable_root")"
  support="$portable_root/$SUPPORT_RELATIVE"
  apps="$portable_root/$APPS_RELATIVE"
  state="$portable_root/$STATE_RELATIVE"
  launcher="$apps/$LAUNCHER_NAME"
  user_application_support_path="$(portable_user_application_support_path)"
  user_preferences_path="$(portable_user_preferences_path)"

  progress_phase 10 "Checking paths"
  if [[ "$mode" == "build" ]] && managed_portable_root_exists "$portable_root"; then
    die "An existing portable installation was found. Use Update Portable Resolve.command instead."
  fi
  if [[ "$mode" == "update" ]] && ! managed_portable_root_exists "$portable_root"; then
    die "No project-managed portable installation was found at this root. Use Build Portable Resolve.command for a new installation."
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

  progress_phase 15 "Checking installer signature"
  if ! run_with_visible_output "Verifying installer signature" pkgutil --check-signature "$pkg"; then
    die "pkgutil could not validate the selected package signature. The package was not extracted."
  fi

  progress_phase 20 "Checking disk space"
  package_bytes="$(file_size_bytes "$pkg" || true)"
  if [[ "$package_bytes" =~ ^[0-9]+$ ]]; then
    # Allow roughly 3x compressed package size plus 1 GiB for expansion/copies.
    preflight_bytes="$((package_bytes * 3 + 1073741824))"
    require_free_space "local staging filesystem" "${TMPDIR:-/tmp}" "$preflight_bytes"
    require_free_space "portable destination filesystem" "$portable_root" "$preflight_bytes"
  else
    warn "Could not determine installer size; continuing with post-expansion space checks."
  fi

  progress_phase 25 "Preparing staging area"
  work="$(mktemp -d "${TMPDIR:-/tmp}/resolve-portable.XXXXXX")"
  INSTALL_WORK_DIR="$work"
  trap cleanup_install_work EXIT
  expanded="$work/expanded"
  progress_phase 40 "Expanding installer"
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

  expanded_bytes="$(tree_size_bytes "$expanded" || true)"
  if [[ "$expanded_bytes" =~ ^[0-9]+$ ]]; then
    local_copy_bytes="$((expanded_bytes + 536870912))"
    require_free_space "local staging filesystem after expansion" "$work" "$local_copy_bytes"
    require_free_space "portable destination filesystem" "$portable_root" "$local_copy_bytes"
  else
    warn "Could not estimate expanded package size."
  fi

  app_name="DaVinci Resolve $version.app"
  staged_app="$work/$app_name"
  progress_phase 60 "Preparing Resolve $version"
  run_with_status "Copying Resolve to local staging" \
    ditto --rsrc --extattr "$extracted_app" "$staged_app" || \
    die "Could not copy Resolve into local staging."
  icon="$extracted_app/Contents/Resources/Resolve.icns"
  [[ -f "$icon" ]] || die "The official app does not contain Contents/Resources/Resolve.icns."

  progress_phase 70 "Building redirect library"
  mkdir -p "$staged_app/Contents/Frameworks"
  if ! "$SCRIPT_DIR/build_redirect.sh" "$support" "$staged_app/Contents/Frameworks/$DYLIB_NAME"; then
    printf '[FAILED] Building redirect library\n' >&2
    die "Could not build the redirect library."
  fi

  progress_phase 78 "Signing Resolve"
  source_executable="$extracted_app/Contents/MacOS/Resolve"
  signature_details="$(codesign -dvv "$source_executable" 2>&1 || true)"
  runtime_option="$(runtime_signing_option "$signature_details")"
  if [[ -n "$runtime_option" ]]; then
    info "The source executable uses Hardened Runtime; preserving the runtime signing option."
  else
    info "The source executable does not use Hardened Runtime; not adding it."
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
  if [[ -n "$runtime_option" ]]; then
    codesign --force --sign - --options runtime --entitlements "$entitlements" "$executable"
  else
    codesign --force --sign - --entitlements "$entitlements" "$executable"
  fi
  codesign --verify --strict "$executable"
  resigned_signature_details="$(codesign -dvv "$executable" 2>&1 || true)"
  if [[ -n "$runtime_option" ]]; then
    code_signature_has_runtime "$resigned_signature_details" || \
      die "The re-signed Resolve executable did not retain Hardened Runtime."
  elif code_signature_has_runtime "$resigned_signature_details"; then
    die "The re-signed Resolve executable unexpectedly gained Hardened Runtime."
  fi
  codesign -d --entitlements :- "$executable" 2>/dev/null | plutil -lint - >/dev/null

  mkdir -p "$support" "$apps" "$state/rollback"
  mkdir -p "$support/User" "$support/User Preferences"

  progress_phase 84 "Installing and validating Resolve"
  incoming="$support/.$app_name.incoming.$$"
  INCOMING_PATH="$incoming"
  rm -rf "$incoming"
  run_with_status "Copying Resolve to the portable destination" \
    ditto --rsrc --extattr "$staged_app" "$incoming" || \
    die "Could not copy Resolve to the portable destination."
  if ! validate_resolve_app "$incoming"; then
    printf '[FAILED] Validating staged Resolve\n' >&2
    die "The staged app failed validation after copying to the portable drive."
  fi

  # Copy package support payloads without assuming a component-package hierarchy.
  progress_phase 90 "Installing support payload"
  if [[ "$mode" == "update" ]]; then
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    SUPPORT_TRANSACTION_ROOT="$support"
    SUPPORT_BACKUP_DIR="$state/rollback/support.$timestamp"
    mkdir -p "$SUPPORT_BACKUP_DIR"
  fi
  while IFS= read -r -d '' payload; do
    while IFS= read -r -d '' payload_item; do
      payload_name="$(basename "$payload_item")"
      case "$payload_name" in
        User|'User Preferences')
          warn "Skipped installer payload directory reserved for mutable user data: $payload_name"
          ;;
        *)
          if [[ "$mode" == "update" ]]; then
            support_backup_seen=0
            for ((index=0; index<${#SUPPORT_ITEMS[@]}; index++)); do
              [[ "${SUPPORT_ITEMS[$index]}" == "$payload_name" ]] && support_backup_seen=1
            done
            if [[ "$support_backup_seen" -eq 0 ]]; then
              if [[ -e "$support/$payload_name" || -L "$support/$payload_name" ]]; then
                run_with_status "Backing up support payload: $payload_name" \
                  ditto "$support/$payload_name" "$SUPPORT_BACKUP_DIR/$payload_name" || \
                  die "Could not back up support payload: $payload_name"
                SUPPORT_ITEMS+=("$payload_name")
                SUPPORT_EXISTED+=(1)
              else
                SUPPORT_ITEMS+=("$payload_name")
                SUPPORT_EXISTED+=(0)
              fi
              SUPPORT_TRANSACTION_ACTIVE=1
            fi
          fi
          run_with_status "Installing support payload: $payload_name" \
            ditto "$payload_item" "$support/$payload_name" || \
            die "Could not install support payload: $payload_name"
          ;;
      esac
    done < <(find "$payload" -mindepth 1 -maxdepth 1 -print0)
  done < <(find_support_payloads "$expanded")

  destination_app="$support/$app_name"
  rollback=""
  prior_app=""
  if [[ -f "$state/current-app" ]]; then
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
  if [[ -n "$prior_app" ]]; then
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    rollback="$state/rollback/$(basename "$prior_app").$timestamp"
    mv "$prior_app" "$rollback"
  fi
  if ! mv "$incoming" "$destination_app"; then
    [[ -n "$rollback" && -e "$rollback" ]] && mv "$rollback" "$prior_app"
    die "Could not activate the staged app; the prior same-version app was restored."
  fi
  INCOMING_PATH=""
  if ! validate_resolve_app "$destination_app"; then
    printf '[FAILED] Validating activated Resolve\n' >&2
    failed="$state/failed-$app_name.$$"
    mv "$destination_app" "$failed"
    [[ -n "$rollback" && -e "$rollback" ]] && mv "$rollback" "$prior_app"
    die "Post-install validation failed. The prior app was restored; failed copy: $failed"
  fi

  progress_phase 94 "Creating launcher"
  if ! "$SCRIPT_DIR/build_launcher.sh" "$destination_app" "$launcher" "$icon"; then
    printf '[FAILED] Creating launcher\n' >&2
    failed="$state/failed-$app_name.$$"
    mv "$destination_app" "$failed"
    [[ -n "$rollback" && -e "$rollback" ]] && mv "$rollback" "$prior_app"
    die "Launcher generation failed. The prior app was restored; failed copy: $failed"
  fi
  printf '%s\n' "$portable_root" > "$state/portable-root"
  printf '%s\n' "$destination_app" > "$state/current-app"
  printf '%s\n' "$version" > "$state/version"
  SUPPORT_TRANSACTION_ACTIVE=0
  mkdir -p "$state/bin"
  for file in 'Update Portable Resolve.command' 'Uninstall.command'; do
    source_file="$PROJECT_DIR/$file"
    [[ -f "$source_file" ]] || source_file="$SCRIPT_DIR/$file"
    cp "$source_file" "$state/bin/$file"
    chmod +x "$state/bin/$file"
  done
  asset_scripts="$PROJECT_DIR/scripts"
  [[ -d "$asset_scripts" ]] || asset_scripts="$SCRIPT_DIR"
  cp "$asset_scripts/diagnose.command" "$state/bin/diagnose.command"
  cp "$asset_scripts/common.sh" "$state/bin/common.sh"
  cp "$asset_scripts/install_core.sh" "$state/bin/install_core.sh"
  cp "$asset_scripts/build_redirect.sh" "$state/bin/build_redirect.sh"
  cp "$asset_scripts/build_launcher.sh" "$state/bin/build_launcher.sh"
  mkdir -p "$state/src"
  source_c="$PROJECT_DIR/src/resolve_redirect.c"
  [[ -f "$source_c" ]] || source_c="$PROJECT_DIR/../src/resolve_redirect.c"
  cp "$source_c" "$state/src/resolve_redirect.c"

  # Make user-Library changes only after the portable install and launcher are ready.
  progress_phase 97 "Creating user symlinks"
  prepare_user_symlink "$user_application_support_path" "$support/User" "Application Support"
  prepare_user_symlink "$user_preferences_path" "$support/User Preferences" "Preferences"

  progress_phase 100 "Portable Resolve ready"
  info "Portable DaVinci Resolve $version is ready."
  info "Launcher: $launcher"
  [[ -n "$rollback" ]] && info "Rollback retained at: $rollback"
  info "The first launch may ask for removable-volume access; choose Allow."
}
