#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$PROJECT_DIR/.test-work"
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
cleanup
mkdir -p "$TEST_ROOT/tmp" "$TEST_ROOT/Portable Root With Spaces"

printf 'Checking shell syntax...\n'
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$PROJECT_DIR" -path "$PROJECT_DIR/known-good" -prune -o \
  -path "$TEST_ROOT" -prune -o -name '._*' -prune -o \
  \( -name '*.sh' -o -name '*.command' \) -type f -print0)

printf 'Testing path rewriting, prefix boundaries, spaces, and overflow...\n'
xcrun clang -arch arm64 -Wall -Wextra -Werror \
  -DRESOLVE_REDIRECT_TESTING \
  '-DRESOLVE_REDIRECT_DESTINATION="/Volumes/Test Drive/Portable Root/Application Support/Blackmagic Design"' \
  "$PROJECT_DIR/src/resolve_redirect.c" "$PROJECT_DIR/tests/rewrite_test.c" \
  -o "$TEST_ROOT/rewrite-test"
"$TEST_ROOT/rewrite-test"

printf 'Building the arm64 redirector inside the workspace...\n'
redirect_destination="$TEST_ROOT/Portable Root With Spaces/Application Support/Blackmagic Design"
mkdir -p "$redirect_destination"
"$PROJECT_DIR/scripts/build_redirect.sh" "$redirect_destination" "$TEST_ROOT/resolve-redirect.dylib"
file "$TEST_ROOT/resolve-redirect.dylib" | grep -q arm64
strings "$TEST_ROOT/resolve-redirect.dylib" | grep -Fq "$redirect_destination"

printf 'Testing app discovery, version detection, and symlink classification...\n'
source "$PROJECT_DIR/scripts/common.sh"

printf 'Testing BSD-awk-compatible byte formatting...\n'
[[ "$(human_bytes 0)" == '0.0 B' ]]
[[ "$(human_bytes 1023)" == '1023.0 B' ]]
[[ "$(human_bytes 1024)" == '1.0 KiB' ]]
[[ "$(human_bytes 1536)" == '1.5 KiB' ]]
[[ "$(human_bytes 1048576)" == '1.0 MiB' ]]
[[ "$(human_bytes 1073741824)" == '1.0 GiB' ]]
[[ "$(human_bytes 1099511627776)" == '1.0 TiB' ]]
space_message="$(require_free_space 'test filesystem' "$TEST_ROOT" 1)"
grep -Eq 'free space: [0-9]+\.[0-9] (B|KiB|MiB|GiB|TiB); conservative requirement: [0-9]+\.[0-9] (B|KiB|MiB|GiB|TiB)\.' \
  <<<"$space_message"
if grep -Fq 'free space: ;' <<<"$space_message" || \
   grep -Fq 'conservative requirement: .' <<<"$space_message"; then
  printf 'Free-space message contained a blank formatted value\n' >&2
  exit 1
fi

printf 'Testing phase progress, failure handling, and nonanimated command status...\n'
progress_output="$(progress_reset
  progress_phase 5 'Preflight'
  progress_phase 40 'Expanding installer'
  progress_phase 100 'Portable Resolve ready')"
progress_last=-1
while IFS= read -r progress_percent; do
  [[ "$progress_percent" -ge "$progress_last" ]]
  progress_last="$progress_percent"
done < <(printf '%s\n' "$progress_output" | sed -n 's/^\[[^]]*\][[:space:]]*\([0-9][0-9]*\)%.*$/\1/p')
[[ "$progress_last" -eq 100 ]]
grep -Fq '100% Portable Resolve ready' <<<"$progress_output"

actual_phase_last=-1
while IFS= read -r progress_percent; do
  [[ "$progress_percent" -ge "$actual_phase_last" ]]
  actual_phase_last="$progress_percent"
done < <(sed -n 's/.*progress_phase \([0-9][0-9]*\) .*/\1/p' \
  "$PROJECT_DIR/scripts/install_core.sh")
[[ "$actual_phase_last" -eq 100 ]]

set +e
failure_output="$(
  {
    progress_reset
    progress_phase 10 'Before simulated failure'
    if DAVINCI_PORTABLE_NO_ANIMATION=1 run_with_status 'Simulated failing command' \
      sh -c 'printf "simulated command error\\n" >&2; exit 7'; then
      progress_phase 100 'Should not appear'
      exit 0
    else
      exit $?
    fi
  } 2>&1)"
failure_status=$?
set -e
[[ "$failure_status" -eq 7 ]]
grep -Fq '[FAILED] Simulated failing command' <<<"$failure_output"
grep -Fq 'simulated command error' <<<"$failure_output"
if grep -Fq '100%' <<<"$failure_output"; then
  printf 'Failed progress flow incorrectly reached 100%%\n' >&2
  exit 1
fi

set +e
DAVINCI_PORTABLE_NO_ANIMATION=1 run_with_status 'Exit-status test' sh -c 'exit 23' \
  >"$TEST_ROOT/status-output" 2>&1
status_result=$?
set -e
[[ "$status_result" -eq 23 ]]
if DAVINCI_PORTABLE_NO_ANIMATION=1 progress_animation_enabled; then
  printf 'DAVINCI_PORTABLE_NO_ANIMATION did not disable animation\n' >&2
  exit 1
fi
no_animation_output="$(DAVINCI_PORTABLE_NO_ANIMATION=1 \
  run_with_status 'Nonanimated test' sh -c 'exit 0')"
grep -Fq '==> Nonanimated test...' <<<"$no_animation_output"
if [[ "$no_animation_output" == *$'\r'* ]]; then
  printf 'Nonanimated command status emitted carriage-return animation\n' >&2
  exit 1
fi

printf 'Testing visible-output command status without spinner interleaving...\n'
visible_output="$(run_with_visible_output 'Certificate inspection' \
  sh -c 'printf "Certificate 1: Example Signer\\n"')"
grep -Fq '==> Certificate inspection...' <<<"$visible_output"
grep -Fq 'Certificate 1: Example Signer' <<<"$visible_output"
if [[ "$visible_output" == *$'\r'* ]]; then
  printf 'Visible-output command emitted spinner carriage returns\n' >&2
  exit 1
fi
set +e
run_with_visible_output 'Visible failure' \
  sh -c 'printf "visible command error\\n" >&2; exit 19' \
  >"$TEST_ROOT/visible-status-output" 2>&1
visible_status=$?
set -e
[[ "$visible_status" -eq 19 ]]
grep -Fq 'visible command error' "$TEST_ROOT/visible-status-output"
grep -Fq '[FAILED] Visible failure' "$TEST_ROOT/visible-status-output"
if [[ "$(cat "$TEST_ROOT/visible-status-output")" == *$'\r'* ]]; then
  printf 'Visible failure emitted spinner carriage returns\n' >&2
  exit 1
fi

grep -Fq 'run_with_visible_output "Verifying installer signature" pkgutil --check-signature' \
  "$PROJECT_DIR/scripts/install_core.sh"
if grep -Fq 'run_with_status "Verifying installer signature"' \
  "$PROJECT_DIR/scripts/install_core.sh"; then
  printf 'Installer signature check still uses the animated helper\n' >&2
  exit 1
fi

fake_expanded="$TEST_ROOT/Fake Expanded Package/Payload/Applications/DaVinci Resolve"
fake_app="$fake_expanded/DaVinci Resolve.app"
mkdir -p "$fake_app/Contents/MacOS"
touch "$fake_app/Contents/MacOS/Resolve"
chmod +x "$fake_app/Contents/MacOS/Resolve"
plutil -create xml1 "$fake_app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.blackmagic-design.DaVinciResolve "$fake_app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 99.7.3 "$fake_app/Contents/Info.plist"
[[ "$(find_resolve_app "$TEST_ROOT/Fake Expanded Package")" == "$fake_app" ]]
[[ "$(resolve_version "$fake_app")" == "99.7.3" ]]

fake_home="$TEST_ROOT/Fake Home"
expected="$TEST_ROOT/Portable Root With Spaces/Application Support/Blackmagic Design/User"
mkdir -p "$fake_home/Library/Application Support" "$expected"
link="$fake_home/Library/Application Support/Blackmagic Design"
[[ "$(symlink_state "$link" "$expected")" == missing ]]
mkdir "$link"
[[ "$(symlink_state "$link" "$expected")" == empty-directory ]]
touch "$link/existing-project.db"
[[ "$(symlink_state "$link" "$expected")" == nonempty-directory ]]
rm "$link/existing-project.db"
rmdir "$link"
ln -s "$expected" "$link"
[[ "$(symlink_state "$link" "$expected")" == valid ]]

printf 'Testing managed-root Build refusal...\n'
managed_root="$TEST_ROOT/Existing Managed Root"
mkdir -p "$managed_root/.davinci-resolve-portable"
printf '%s\n' "$managed_root" > "$managed_root/.davinci-resolve-portable/portable-root"
fake_pkg="$TEST_ROOT/Official Installer.pkg"
touch "$fake_pkg"

printf 'Testing DAVINCI_PORTABLE_HOME_OVERRIDE through the actual Build preflight...\n'
override_real_home="$TEST_ROOT/Override Real Home"
override_fake_home="$TEST_ROOT/Override Fake Home"
override_root="$TEST_ROOT/Override Build Root"
conflict_target="$TEST_ROOT/Conflicting Existing Target"
mkdir -p "$override_real_home/Library/Application Support" \
  "$override_real_home/Library/Preferences" \
  "$override_fake_home/Library/Application Support" \
  "$override_fake_home/Library/Preferences" \
  "$override_root" "$conflict_target"
ln -s "$conflict_target" \
  "$override_real_home/Library/Application Support/Blackmagic Design"
ln -s "$conflict_target" \
  "$override_real_home/Library/Preferences/Blackmagic Design"

[[ "$(HOME="$override_real_home" DAVINCI_PORTABLE_HOME_OVERRIDE= portable_user_home)" == \
  "$override_real_home" ]]
[[ "$(HOME="$override_real_home" DAVINCI_PORTABLE_HOME_OVERRIDE="$override_fake_home" \
  portable_user_home)" == "$override_fake_home" ]]
[[ "$(HOME="$override_real_home" DAVINCI_PORTABLE_HOME_OVERRIDE="$override_fake_home" \
  portable_user_application_support_path)" == \
  "$override_fake_home/Library/Application Support/Blackmagic Design" ]]
[[ "$(HOME="$override_real_home" DAVINCI_PORTABLE_HOME_OVERRIDE="$override_fake_home" \
  portable_user_preferences_path)" == \
  "$override_fake_home/Library/Preferences/Blackmagic Design" ]]

set +e
override_build_output="$(HOME="$override_real_home" \
  DAVINCI_PORTABLE_HOME_OVERRIDE="$override_fake_home" TMPDIR="$TEST_ROOT/tmp" \
  "$PROJECT_DIR/Build Portable Resolve.command" "$fake_pkg" "$override_root" 2>&1)"
override_build_status=$?
set -e
[[ "$override_build_status" -ne 0 ]]
grep -Fq 'Checking installer signature' <<<"$override_build_output"
grep -Fq 'Verifying installer signature' <<<"$override_build_output"
if grep -Fq "$override_real_home/Library" <<<"$override_build_output"; then
  printf 'Build preflight incorrectly evaluated the real HOME\n' >&2
  exit 1
fi
[[ -L "$override_real_home/Library/Application Support/Blackmagic Design" ]]
[[ -L "$override_real_home/Library/Preferences/Blackmagic Design" ]]
[[ ! -e "$override_fake_home/Library/Application Support/Blackmagic Design" ]]
[[ ! -L "$override_fake_home/Library/Application Support/Blackmagic Design" ]]
[[ ! -e "$override_fake_home/Library/Preferences/Blackmagic Design" ]]
[[ ! -L "$override_fake_home/Library/Preferences/Blackmagic Design" ]]

set +e
build_output="$(HOME="$fake_home" bash -c \
  'source "$1/scripts/install_core.sh"; install_from_pkg build "$2" "$3"' \
  _ "$PROJECT_DIR" "$fake_pkg" "$managed_root" 2>&1)"
build_status=$?
set -e
[[ "$build_status" -ne 0 ]]
grep -Fq 'An existing portable installation was found. Use Update Portable Resolve.command instead.' \
  <<<"$build_output"

printf 'Testing unmanaged-root Update refusal...\n'
unmanaged_root="$TEST_ROOT/Unmanaged Root"
guard_home="$TEST_ROOT/Guard Home"
mkdir -p "$unmanaged_root" "$guard_home/Library/Application Support" "$guard_home/Library/Preferences"
set +e
update_output="$(HOME="$guard_home" bash -c \
  'source "$1/scripts/install_core.sh"; install_from_pkg update "$2" "$3"' \
  _ "$PROJECT_DIR" "$fake_pkg" "$unmanaged_root" 2>&1)"
update_status=$?
set -e
[[ "$update_status" -ne 0 ]]
grep -Fq 'No project-managed portable installation was found at this root. Use Build Portable Resolve.command for a new installation.' \
  <<<"$update_output"
[[ ! -e "$guard_home/Library/Application Support/Blackmagic Design" ]]
[[ ! -L "$guard_home/Library/Application Support/Blackmagic Design" ]]
[[ ! -e "$guard_home/Library/Preferences/Blackmagic Design" ]]
[[ ! -L "$guard_home/Library/Preferences/Blackmagic Design" ]]

printf 'Checking that real symlink creation occurs only after launcher activation...\n'
preflight_line="$(grep -nF 'preflight_user_symlink "$user_application_support_path"' \
  "$PROJECT_DIR/scripts/install_core.sh" | cut -d: -f1)"
launcher_line="$(grep -nF 'if ! "$SCRIPT_DIR/build_launcher.sh"' \
  "$PROJECT_DIR/scripts/install_core.sh" | cut -d: -f1)"
prepare_line="$(grep -nF 'prepare_user_symlink "$user_application_support_path"' \
  "$PROJECT_DIR/scripts/install_core.sh" | cut -d: -f1)"
[[ "$preflight_line" -lt "$launcher_line" ]]
[[ "$prepare_line" -gt "$launcher_line" ]]

printf 'Testing runtime-option selection against actual CodeDirectory output...\n'
runtime_binary="$TEST_ROOT/runtime-option-test"
xcrun clang -arch arm64 "$PROJECT_DIR/tests/fake_resolve.c" -o "$runtime_binary"
codesign --force --sign - --options runtime "$runtime_binary"
runtime_details="$(codesign -dvv "$runtime_binary" 2>&1)"
[[ "$(runtime_signing_option "$runtime_details")" == '--options runtime' ]]
codesign --force --sign - "$runtime_binary"
nonruntime_details="$(codesign -dvv "$runtime_binary" 2>&1)"
[[ -z "$(runtime_signing_option "$nonruntime_details")" ]]

printf 'Testing boolean-entitlement helpers and app validation...\n'
entitlements="$TEST_ROOT/test-entitlements.plist"
plutil -create xml1 "$entitlements"
/usr/libexec/PlistBuddy -c \
  'Add :com.apple.security.cs.allow-dyld-environment-variables bool true' "$entitlements"
/usr/libexec/PlistBuddy -c \
  'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
plist_boolean_is_true "$entitlements" com.apple.security.cs.allow-dyld-environment-variables
/usr/libexec/PlistBuddy -c \
  'Set :com.apple.security.cs.allow-dyld-environment-variables false' "$entitlements"
if plist_boolean_is_true "$entitlements" com.apple.security.cs.allow-dyld-environment-variables; then
  printf 'False entitlement was incorrectly accepted\n' >&2
  exit 1
fi
if plist_boolean_is_true "$entitlements" com.example.missing; then
  printf 'Missing entitlement was incorrectly accepted\n' >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c \
  'Set :com.apple.security.cs.allow-dyld-environment-variables true' "$entitlements"

validation_app="$TEST_ROOT/Validation App/DaVinci Resolve.app"
mkdir -p "$validation_app/Contents/MacOS" "$validation_app/Contents/Frameworks"
xcrun clang -arch arm64 "$PROJECT_DIR/tests/fake_resolve.c" \
  -o "$validation_app/Contents/MacOS/Resolve"
cp "$TEST_ROOT/resolve-redirect.dylib" \
  "$validation_app/Contents/Frameworks/resolve-redirect.dylib"
plutil -create xml1 "$validation_app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 99.7.3 "$validation_app/Contents/Info.plist"
codesign --force --sign - --entitlements "$entitlements" \
  "$validation_app/Contents/MacOS/Resolve"
TMPDIR="$TEST_ROOT/tmp" validate_resolve_app "$validation_app"
/usr/libexec/PlistBuddy -c \
  'Set :com.apple.security.cs.disable-library-validation false' "$entitlements"
codesign --force --sign - --entitlements "$entitlements" \
  "$validation_app/Contents/MacOS/Resolve"
if TMPDIR="$TEST_ROOT/tmp" validate_resolve_app "$validation_app"; then
  printf 'App validation accepted a false required entitlement\n' >&2
  exit 1
fi

printf 'Generating and linting the launcher plist contract...\n'
plist="$TEST_ROOT/generated-launcher-Info.plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string io.github.MES30004E.davinci-resolve-portable "$plist"
plutil -insert CFBundleName -string 'DaVinci Resolve' "$plist"
plutil -insert CFBundleDisplayName -string 'DaVinci Resolve' "$plist"
plutil -insert CFBundleIconFile -string Resolve.icns "$plist"
plutil -insert NSRemovableVolumesUsageDescription -string \
  'DaVinci Resolve Portable needs access to its application and support files stored on this external drive.' "$plist"
plutil -lint "$plist" >/dev/null
[[ "$(plist_value "$plist" CFBundleIdentifier)" == io.github.MES30004E.davinci-resolve-portable ]]
[[ "$(plist_value "$plist" CFBundleIconFile)" == Resolve.icns ]]
if plist_value "$plist" CFBundleIconName >/dev/null 2>&1; then
  printf 'CFBundleIconName was not removed\n' >&2
  exit 1
fi
grep -Fq 'quoted form of redirectLibrary' "$PROJECT_DIR/scripts/build_launcher.sh"
grep -Fq 'quoted form of resolveExecutable' "$PROJECT_DIR/scripts/build_launcher.sh"
grep -Fq '>/dev/null 2>&1 &' "$PROJECT_DIR/scripts/build_launcher.sh"
if grep -Fq '/tmp/davinci-resolve-portable.log' "$PROJECT_DIR/scripts/build_launcher.sh"; then
  printf 'Normal launcher still references the former /tmp log\n' >&2
  exit 1
fi

printf 'Checking publishable files for machine-specific paths and usernames...\n'
forbidden_volume='/Volumes/My'" Passport"
forbidden_username='morgan'"stark"
leak_found=0
while IFS= read -r -d '' publishable; do
  if grep -nF "$forbidden_volume" "$publishable"; then
    leak_found=1
  fi
  if grep -nF "$forbidden_username" "$publishable"; then
    leak_found=1
  fi
done < <(find "$PROJECT_DIR" \
  -path "$PROJECT_DIR/known-good" -prune -o \
  -path "$TEST_ROOT" -prune -o \
  -name CONTEXT.md -prune -o -name '._*' -prune -o \
  -type f -print0)
if [[ "$leak_found" -ne 0 ]]; then
  printf 'A machine-specific path or username appears in publishable files\n' >&2
  exit 1
fi

printf 'Auditing executable project code for direct managed paths under HOME...\n'
managed_path_violation=0
while IFS= read -r -d '' code_file; do
  if grep -nE '\$HOME/Library/(Application Support|Preferences)/Blackmagic Design|\$\{HOME\}/Library/(Application Support|Preferences)/Blackmagic Design|~/Library/(Application Support|Preferences)/Blackmagic Design' \
    "$code_file"; then
    managed_path_violation=1
  fi
done < <(find "$PROJECT_DIR/scripts" -type f \( -name '*.sh' -o -name '*.command' \) -print0)
while IFS= read -r -d '' code_file; do
  if grep -nE '\$HOME/Library/(Application Support|Preferences)/Blackmagic Design|\$\{HOME\}/Library/(Application Support|Preferences)/Blackmagic Design|~/Library/(Application Support|Preferences)/Blackmagic Design' \
    "$code_file"; then
    managed_path_violation=1
  fi
done < <(find "$PROJECT_DIR" -maxdepth 1 -type f -name '*.command' -print0)
if [[ "$managed_path_violation" -ne 0 ]]; then
  printf 'Executable project code constructs a managed Blackmagic path directly from HOME\n' >&2
  exit 1
fi

printf 'Testing unowned-root uninstall preserves user data without a deletion prompt...\n'
uninstall_root="$TEST_ROOT/Unowned Uninstall Root"
uninstall_home="$TEST_ROOT/Uninstall Home"
uninstall_support="$uninstall_root/Application Support/Blackmagic Design"
mkdir -p "$uninstall_support/User" "$uninstall_support/User Preferences" \
  "$uninstall_home/Library/Application Support" "$uninstall_home/Library/Preferences"
touch "$uninstall_support/User/project.db" "$uninstall_support/User Preferences/preferences.db"
uninstall_output="$(printf 'y\ny\n' | HOME="$uninstall_home" \
  bash "$PROJECT_DIR/Uninstall.command" "$uninstall_root" 2>&1)"
[[ -f "$uninstall_support/User/project.db" ]]
[[ -f "$uninstall_support/User Preferences/preferences.db" ]]
grep -Fq 'User data was preserved because the selected root could not be verified as owned by this project.' \
  <<<"$uninstall_output"
if grep -Fq 'Also delete portable User and User Preferences data?' <<<"$uninstall_output"; then
  printf 'Uninstaller offered user-data deletion for an unowned root\n' >&2
  exit 1
fi

printf 'All safe workspace-only tests passed.\n'
