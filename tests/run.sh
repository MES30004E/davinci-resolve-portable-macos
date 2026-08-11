#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$PROJECT_DIR/.test-work"
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
cleanup
mkdir -p "$TEST_ROOT/tmp" "$TEST_ROOT/Portable Root With Spaces"

assert_text_contains() {
  local output="$1" expected="$2" message="$3"
  if [[ "$output" != *"$expected"* ]]; then
    printf 'Dashboard test failed: %s\n' "$message" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1" expected="$2" message="$3"
  if ! grep -Fq "$expected" "$file"; then
    printf 'Dashboard test failed: %s\n' "$message" >&2
    exit 1
  fi
}

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
source "$PROJECT_DIR/scripts/update_helpers.sh"

printf 'Testing centralized path-input normalization...\n'
[[ "$(normalize_path_input '/Volumes/Blackmagic DaVinci Resolve/Install Resolve.pkg')" == \
  '/Volumes/Blackmagic DaVinci Resolve/Install Resolve.pkg' ]]
[[ "$(normalize_path_input '/Volumes/Blackmagic\ DaVinci\ Resolve/Install\ Resolve.pkg')" == \
  '/Volumes/Blackmagic DaVinci Resolve/Install Resolve.pkg' ]]
[[ "$(normalize_path_input "'/Volumes/Blackmagic DaVinci Resolve/Install Resolve.pkg'")" == \
  '/Volumes/Blackmagic DaVinci Resolve/Install Resolve.pkg' ]]
[[ "$(normalize_path_input '"/Volumes/Blackmagic DaVinci Resolve/Install Resolve.pkg"')" == \
  '/Volumes/Blackmagic DaVinci Resolve/Install Resolve.pkg' ]]
[[ "$(normalize_path_input "/Volumes/Morgan's Drive/Install Resolve.pkg")" == \
  "/Volumes/Morgan's Drive/Install Resolve.pkg" ]]
[[ "$(normalize_path_input "'/Volumes/Morgan's Drive/Install Resolve.pkg'")" == \
  "/Volumes/Morgan's Drive/Install Resolve.pkg" ]]
[[ "$(normalize_path_input $'  /Volumes/Trailing Space Test/Install.pkg  \t\r')" == \
  '/Volumes/Trailing Space Test/Install.pkg' ]]
for malformed_path in 'relative/path.pkg' "'/Volumes/unmatched.pkg" '/Volumes/trailing\'; do
  if normalize_path_input "$malformed_path" >/dev/null 2>&1; then
    printf 'Malformed path input was accepted: %s\n' "$malformed_path" >&2
    exit 1
  fi
done

printf 'Testing numeric Resolve version comparison and confirmation logic...\n'
[[ "$(version_compare 21.0.4 21.1)" -eq -1 ]]
[[ "$(version_compare 21.1 21.1.1)" -eq -1 ]]
[[ "$(version_compare 21.1.0 21.1)" -eq 0 ]]
[[ "$(version_compare 21.10 21.9)" -eq 1 ]]
confirm_version_transition 21.0.4 21.1
if printf '\n' | confirm_version_transition 21.1 21.1 >/dev/null 2>&1; then
  printf 'Same-version repair default was not refusal\n' >&2
  exit 1
fi
printf 'y\n' | confirm_version_transition 21.1 21.1 >/dev/null 2>&1
if printf '\n' | confirm_version_transition 21.1 21.0.4 >/dev/null 2>&1; then
  printf 'Downgrade default was not refusal\n' >&2
  exit 1
fi
printf 'yes\n' | confirm_version_transition 21.1 21.0.4 >/dev/null 2>&1

printf 'Testing BSD-awk-compatible byte formatting...\n'
[[ "$(human_bytes 0)" == '0.0 B' ]]
[[ "$(human_bytes 1023)" == '1023.0 B' ]]
[[ "$(human_bytes 1024)" == '1.0 KiB' ]]
[[ "$(human_bytes 1536)" == '1.5 KiB' ]]
[[ "$(human_bytes 1048576)" == '1.0 MiB' ]]
[[ "$(human_bytes 1073741824)" == '1.0 GiB' ]]
[[ "$(human_bytes 1099511627776)" == '1.0 TiB' ]]
[[ "$(format_duration 0)" == '00:00' ]]
[[ "$(format_duration 65)" == '01:05' ]]
[[ "$(format_duration 3661)" == '01:01:01' ]]
[[ "$(format_rate 10485760 10)" == '1.0 MiB/s' ]]
[[ "$(estimated_eta 1000 100 2)" == 'estimating...' ]]
[[ "$(estimated_eta 1000 250 5)" == '00:15' ]]
[[ "$(estimated_eta 1000 500 10)" == '00:10' ]]
[[ "$(estimated_eta 1000 750 15)" == '00:05' ]]
[[ "$(estimated_eta 1000 500 20)" == '00:20' ]]
[[ "$(estimated_eta 1000 1100 20)" == '00:00' ]]
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
done < <(printf '%s\n' "$progress_output" | sed -n 's/^\[[[:space:]]*\([0-9][0-9]*\)%\].*$/\1/p')
[[ "$progress_last" -eq 100 ]]
grep -Fq '[100%] Portable Resolve ready' <<<"$progress_output"

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
grep -Fq '==> Nonanimated test' <<<"$no_animation_output"
if [[ "$no_animation_output" == *$'\r'* || "$no_animation_output" == *$'\033'* ]]; then
  printf 'Nonanimated command status emitted terminal redraw controls\n' >&2
  exit 1
fi
if [[ "$no_animation_output" == *'Working  '* || "$no_animation_output" == *'◐'* || \
      "$no_animation_output" == *'◓'* || "$no_animation_output" == *'◑'* || \
      "$no_animation_output" == *'◒'* ]]; then
  printf 'Nonanimated command status emitted dashboard or spinner output\n' >&2
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

printf 'Testing fixed-row dashboard, spinner, and clean ANSI rendering...\n'
DAVINCI_PORTABLE_NO_ANIMATION=0 TERM=xterm-256color \
  DAVINCI_PORTABLE_FORCE_INTERACTIVE=1 bash -c '
  source "$1/scripts/common.sh"
  progress_reset
  progress_phase 5 "Preflight"
  progress_phase 40 "Expanding installer"
  UI_PHASE_SAMPLE_COUNT=1
  UI_OVERALL_ETA_UPDATED_AT=0
  ui_update_overall_eta 0
  ui_dashboard_set_indeterminate "Progress   indeterminate" "Expanded 2.0 GiB" \
    "Contents/Resources/example.file"
  ui_dashboard_begin
  ui_dashboard_render
  ui_dashboard_end
' _ "$PROJECT_DIR" > "$TEST_ROOT/interactive-progress-output"
interactive_progress_output="$(cat "$TEST_ROOT/interactive-progress-output")"
assert_text_contains "$interactive_progress_output" $'\033[13A' \
  'expected ANSI cursor-up sequence.'
assert_text_contains "$interactive_progress_output" 'Working  ' \
  'expected working/spinner row.'
if [[ "$interactive_progress_output" != *'◐'* && "$interactive_progress_output" != *'◓'* ]]; then
  printf 'Dashboard test failed: expected spinner frame.\n' >&2
  exit 1
fi
assert_file_contains "$TEST_ROOT/interactive-progress-output" \
  'Contents/Resources/example.file' 'expected current-file field.'
assert_file_contains "$TEST_ROOT/interactive-progress-output" 'Time left  ~' \
  'expected approximate Time left field.'
assert_file_contains "$PROJECT_DIR/scripts/common.sh" 'UI_DASHBOARD_ROWS=13' \
  'expected fixed dashboard row count.'

printf 'Testing controlled Time-left dashboard states...\n'
DAVINCI_PORTABLE_NO_ANIMATION=0 TERM=xterm-256color \
  DAVINCI_PORTABLE_FORCE_INTERACTIVE=1 bash -c '
  source "$1/scripts/common.sh"
  progress_reset
  progress_phase 40 "Expanding installer"
  ui_dashboard_set_indeterminate "Progress   indeterminate" "Expanded 1.0 GiB" "Payload/example"
  ui_dashboard_begin; ui_dashboard_render; ui_dashboard_end

  progress_phase 60 "Signing Resolve"
  UI_OVERALL_ETA_SECONDS=135
  ui_dashboard_set_indeterminate "Progress   indeterminate" "Elapsed 00:06" "Contents/MacOS/Resolve"
  ui_dashboard_begin; ui_dashboard_render; ui_dashboard_end

  ui_dashboard_set_copy "Copy" 51 2469606195 4831838208 "318.0 MiB/s" "00:07" \
    "Contents/Frameworks/libDaVinciPanelAPI.dylib"
  ui_dashboard_begin; ui_dashboard_render; ui_dashboard_end

  ui_dashboard_set_copy "Copy" 100 4831838208 4831838208 "318.0 MiB/s" "00:00" \
    "Contents/Frameworks/libDaVinciPanelAPI.dylib"
  ui_dashboard_begin; ui_dashboard_render; ui_dashboard_end
' _ "$PROJECT_DIR" > "$TEST_ROOT/time-left-states-output"
for dashboard_expectation in \
  'Overall  [########------------] 40%' \
  'Time left  estimating...' \
  'Overall  [############--------] 60%' \
  'Time left  ~02:15' \
  'Phase    Signing Resolve' \
  'Copy     [##########----------] 51%' \
  '2.3 GiB / 4.5 GiB   318.0 MiB/s' \
  'Time left  00:07' \
  'Finalizing files...' \
  'Time left  unavailable'; do
  assert_file_contains "$TEST_ROOT/time-left-states-output" "$dashboard_expectation" \
    "expected controlled state: $dashboard_expectation"
done
if grep -nE 'Overall ETA|ETA unavailable|ETA estimating\.\.\.|ETA:[[:space:]]' \
  "$PROJECT_DIR/scripts/common.sh" "$PROJECT_DIR/scripts/install_core.sh" \
  "$PROJECT_DIR/Build Portable Resolve.command" "$PROJECT_DIR/Update Portable Resolve.command" \
  "$PROJECT_DIR/README.md" "$PROJECT_DIR"/docs/*.md; then
  printf 'A stale user-facing ETA label remains in publishable files\n' >&2
  exit 1
fi

set +e
DAVINCI_PORTABLE_NO_ANIMATION=0 TERM=xterm-256color \
  DAVINCI_PORTABLE_FORCE_INTERACTIVE=1 bash -c '
  source "$1/scripts/common.sh"
  progress_reset
  progress_phase 40 "Expanding installer"
  run_with_status "Simulated long operation" sh -c "sleep 0.7; exit 17"
' _ "$PROJECT_DIR" > "$TEST_ROOT/interactive-failure-output" 2>&1
interactive_failure_status=$?
set -e
[[ "$interactive_failure_status" -eq 17 ]]
assert_file_contains "$TEST_ROOT/interactive-failure-output" \
  '[FAILED] Simulated long operation' 'expected interactive failure status.'
assert_file_contains "$TEST_ROOT/interactive-failure-output" $'\033[?25h' \
  'expected cursor restoration after interactive failure.'
if grep -q '^    elapsed ' "$TEST_ROOT/interactive-failure-output"; then
  printf 'Dashboard operation appended elapsed-time log lines\n' >&2
  exit 1
fi

DAVINCI_PORTABLE_NO_ANIMATION=0 TERM=xterm-256color \
  DAVINCI_PORTABLE_FORCE_INTERACTIVE=1 bash -c '
  source "$1/scripts/common.sh"
  progress_reset
  progress_phase 15 "Checking installer signature"
  run_with_visible_output "Certificate inspection" \
    sh -c "printf \"Certificate 1: Example Signer\\n\""
' _ "$PROJECT_DIR" > "$TEST_ROOT/interactive-visible-output" 2>&1
grep -q '^Certificate 1: Example Signer$' "$TEST_ROOT/interactive-visible-output"

printf 'Testing expansion activity and monitored staging size...\n'
expanded_monitor="$TEST_ROOT/Expansion Monitor"
DAVINCI_PORTABLE_NO_ANIMATION=0 TERM=xterm-256color DAVINCI_PORTABLE_FORCE_INTERACTIVE=1 \
  DAVINCI_PORTABLE_STATUS_MONITOR_PATH="$expanded_monitor" bash -c '
  source "$1/scripts/common.sh"
  run_with_status "Expanding installer" sh -c \
    "mkdir -p \"$2\"; dd if=/dev/zero of=\"$2/chunk\" bs=1024 count=32 >/dev/null 2>&1; sleep 2.2"
' _ "$PROJECT_DIR" "$expanded_monitor" > "$TEST_ROOT/expansion-status-output"
grep -Fq 'Expanded ' "$TEST_ROOT/expansion-status-output"
grep -Fq 'Time left  unavailable' "$TEST_ROOT/expansion-status-output"
if grep -q '^    elapsed ' "$TEST_ROOT/expansion-status-output"; then
  printf 'Expansion dashboard appended elapsed-time log lines\n' >&2
  exit 1
fi

printf 'Testing real byte copy progress and activity prefixes...\n'
copy_source="$TEST_ROOT/Copy Source.app"
copy_destination="$TEST_ROOT/Copy Destination.app"
mkdir -p "$copy_source/Contents/Frameworks" "$copy_source/Contents/Resources"
dd if=/dev/zero of="$copy_source/Contents/Frameworks/test.bin" bs=1024 count=64 \
  >/dev/null 2>&1
printf 'PRIVATE_SOURCE_CONTENT_MUST_NOT_APPEAR\n' \
  > "$copy_source/Contents/Resources/private-fixture.txt"
set +e
DAVINCI_PORTABLE_NO_ANIMATION=1 run_copy_with_progress 'Copy fixture' \
  "$copy_source" "$copy_destination" '+' copy ditto "$copy_source" "$copy_destination" \
  > "$TEST_ROOT/copy-progress-output"
copy_fixture_status=$?
set -e
if [[ "$copy_fixture_status" -ne 0 ]]; then
  printf 'Copy progress fixture failed with status %s:\n' "$copy_fixture_status" >&2
  sed -n '1,100p' "$TEST_ROOT/copy-progress-output" >&2
  exit 1
fi
grep -Eq 'copy: .* / .*100%' "$TEST_ROOT/copy-progress-output" || {
  printf 'Final byte progress missing:\n' >&2; sed -n '1,80p' "$TEST_ROOT/copy-progress-output" >&2; exit 1;
}
cmp "$copy_source/Contents/Frameworks/test.bin" \
  "$copy_destination/Contents/Frameworks/test.bin" || {
    printf 'Copy fixture contents differ\n' >&2; exit 1;
  }

printf 'Testing observed current files, interpolated overall progress, and finalizing state...\n'
dashboard_source="$TEST_ROOT/Dashboard Source.app"
dashboard_destination="$TEST_ROOT/Dashboard Destination.app"
mkdir -p "$dashboard_source/Contents/Frameworks"
dd if=/dev/zero of="$dashboard_source/Contents/Frameworks/first.dylib" bs=1024 count=32 \
  >/dev/null 2>&1
dd if=/dev/zero of="$dashboard_source/Contents/Frameworks/second.dylib" bs=1024 count=32 \
  >/dev/null 2>&1
DAVINCI_PORTABLE_NO_ANIMATION=0 TERM=xterm-256color DAVINCI_PORTABLE_FORCE_INTERACTIVE=1 \
  DAVINCI_PORTABLE_OPERATION_END_PERCENT=70 bash -c '
  source "$1/scripts/common.sh"
  progress_reset
  progress_phase 60 "Installing Resolve"
  run_copy_with_progress "Dashboard copy" "$2" "$3" "+" copy sh -c \
    "mkdir -p \"$3/Contents/Frameworks\"; cp \"$2/Contents/Frameworks/first.dylib\" \"$3/Contents/Frameworks/\"; sleep 1.2; cp \"$2/Contents/Frameworks/second.dylib\" \"$3/Contents/Frameworks/\"; sleep 1.6"
' _ "$PROJECT_DIR" "$dashboard_source" "$dashboard_destination" \
  > "$TEST_ROOT/dashboard-copy-output"
grep -Fq 'Contents/Frameworks/first.dylib' "$TEST_ROOT/dashboard-copy-output" || {
  printf 'Dashboard did not observe first copied file\n' >&2; exit 1;
}
grep -Fq 'Contents/Frameworks/second.dylib' "$TEST_ROOT/dashboard-copy-output" || {
  printf 'Dashboard did not observe second copied file\n' >&2; exit 1;
}
grep -Fq 'Finalizing files...' "$TEST_ROOT/dashboard-copy-output" || {
  printf 'Dashboard did not show finalizing state\n' >&2; exit 1;
}
grep -Eq 'Overall  \[[#-]+\] 6[1-9]%' "$TEST_ROOT/dashboard-copy-output" || {
  printf 'Dashboard did not interpolate overall progress\n' >&2; exit 1;
}
[[ "$(grep -c '^✓ copied' "$TEST_ROOT/dashboard-copy-output")" -eq 1 ]]
if grep -q '^+ copy' "$TEST_ROOT/dashboard-copy-output"; then
  printf 'Normal dashboard permanently logged individual files\n' >&2
  exit 1
fi

long_dashboard_path='Contents/Frameworks/Very/Long/Component/Tree/libDaVinciControlPanels.dylib'
truncated_dashboard_path="$(truncate_dashboard_text "$long_dashboard_path" 48)"
[[ "${#truncated_dashboard_path}" -le 48 ]]
[[ "$truncated_dashboard_path" == Contents/*...*libDaVinciControlPanels.dylib ]]

progress_reset
PROGRESS_LAST_PERCENT=40
UI_PHASE_SAMPLE_COUNT=1
UI_OVERALL_ETA_UPDATED_AT=0
ui_update_overall_eta 0
countdown_early="$UI_OVERALL_ETA_SECONDS"
PROGRESS_LAST_PERCENT=60
UI_DISPLAY_PERCENT=60
UI_OVERALL_ETA_UPDATED_AT=0
ui_update_overall_eta 0
countdown_later="$UI_OVERALL_ETA_SECONDS"
unset UI_DISPLAY_PERCENT
[[ "$countdown_later" -lt "$countdown_early" ]]

UI_OVERALL_ETA_SECONDS=""
PROGRESS_LAST_PERCENT=60
UI_PHASE_SAMPLE_COUNT=1
UI_OVERALL_ETA_UPDATED_AT=0
ui_update_overall_eta 20
first_overall_eta="$UI_OVERALL_ETA_SECONDS"
UI_OVERALL_ETA_UPDATED_AT=0
ui_update_overall_eta 100
second_overall_eta="$UI_OVERALL_ETA_SECONDS"
[[ "$first_overall_eta" =~ ^[0-9]+$ && "$second_overall_eta" =~ ^[0-9]+$ ]]
[[ "$second_overall_eta" -gt "$first_overall_eta" ]]
[[ "$(ui_overall_eta_text)" == '~'* ]]
UI_OVERALL_ETA_SECONDS=""
UI_OVERALL_ETA_UPDATED_AT=0
ui_update_overall_eta -10000
[[ "$UI_OVERALL_ETA_SECONDS" -eq 0 ]]

activity_output="$(activity '>' backup 'DaVinci Resolve.app'; \
  activity '=' preserve 'User/'; activity '-' remove 'old app')"
grep -Fq '> backup' <<<"$activity_output" || { printf '%s\n' "$activity_output" >&2; exit 1; }
grep -Fq '= preserve  User/' <<<"$activity_output" || { printf '%s\n' "$activity_output" >&2; exit 1; }
grep -Fq -- '- remove' <<<"$activity_output" || { printf '%s\n' "$activity_output" >&2; exit 1; }

printf 'Testing verbose file and safe command logging...\n'
verbose_output="$(DAVINCI_PORTABLE_VERBOSE=1 run_copy_with_progress 'Verbose copy' \
  "$copy_source" "$TEST_ROOT/Verbose Copy.app" '+' copy \
  ditto "$copy_source" "$TEST_ROOT/Verbose Copy.app")"
grep -Fq '+ copy      Contents/Frameworks/test.bin' <<<"$verbose_output"
grep -Fq '$ ditto ' <<<"$verbose_output"
if grep -Eq '(^|[[:space:]])(HOME|PATH|USER|SHELL)=' <<<"$verbose_output"; then
  printf 'Verbose output dumped environment variables\n' >&2
  exit 1
fi
if grep -Fq 'PRIVATE_SOURCE_CONTENT_MUST_NOT_APPEAR' <<<"$verbose_output"; then
  printf 'Verbose output dumped source-file contents\n' >&2
  exit 1
fi

set +e
DAVINCI_PORTABLE_NO_ANIMATION=1 run_copy_with_progress 'Failing copy fixture' \
  "$copy_source" "$TEST_ROOT/Failed Copy.app" '+' copy sh -c 'exit 29' \
  > "$TEST_ROOT/copy-failure-output" 2>&1
copy_failure_status=$?
set -e
[[ "$copy_failure_status" -eq 29 ]]
grep -Fq '[FAILED] Failing copy fixture' "$TEST_ROOT/copy-failure-output"

grep -Fq 'run_with_visible_output "Verifying installer signature" pkgutil --check-signature' \
  "$PROJECT_DIR/scripts/install_core.sh"
if grep -Fq 'run_with_status "Verifying installer signature"' \
  "$PROJECT_DIR/scripts/install_core.sh"; then
  printf 'Installer signature check still uses the animated helper\n' >&2
  exit 1
fi

printf 'Testing same-file-safe installed runtime refresh...\n'
installed_runtime_root="$TEST_ROOT/Installed Updater Root"
installed_runtime_state="$installed_runtime_root/.davinci-resolve-portable"
installed_runtime_bin="$installed_runtime_state/bin"
mkdir -p "$installed_runtime_bin"
printf '%s\n' "$installed_runtime_root" > "$installed_runtime_state/portable-root"
cp "$PROJECT_DIR/scripts/common.sh" "$installed_runtime_bin/common.sh"
cp "$PROJECT_DIR/Update Portable Resolve.command" \
  "$installed_runtime_bin/Update Portable Resolve.command"
chmod +x "$installed_runtime_bin/Update Portable Resolve.command"
same_copy_output="$(DAVINCI_PORTABLE_NO_ANIMATION=1 bash -c '
  source "$1"
  copy_project_runtime_file "$2" "$2" "Update Portable Resolve.command"
' _ "$installed_runtime_bin/common.sh" \
  "$installed_runtime_bin/Update Portable Resolve.command")"
grep -Fq '= keep      installed helper: Update Portable Resolve.command' <<<"$same_copy_output"
grep -Fq 'install_from_pkg update' "$installed_runtime_bin/Update Portable Resolve.command"

ln -s "$installed_runtime_bin/Update Portable Resolve.command" \
  "$installed_runtime_bin/Updater resolved-path alias.command"
copy_project_runtime_file "$installed_runtime_bin/Updater resolved-path alias.command" \
  "$installed_runtime_bin/Update Portable Resolve.command" 'resolved-path alias' \
  > "$TEST_ROOT/resolved-path-refresh-output"
grep -Fq '= keep      installed helper: resolved-path alias' \
  "$TEST_ROOT/resolved-path-refresh-output"

runtime_source="$TEST_ROOT/New Runtime Helper.command"
runtime_destination="$installed_runtime_bin/Uninstall.command"
printf 'new runtime contents\n' > "$runtime_source"
printf 'old runtime contents\n' > "$runtime_destination"
copy_project_runtime_file "$runtime_source" "$runtime_destination" Uninstall.command
cmp "$runtime_source" "$runtime_destination"

printf 'preserve this destination\n' > "$installed_runtime_bin/diagnose.command"
if copy_project_runtime_file "$TEST_ROOT/Missing Runtime Helper.command" \
  "$installed_runtime_bin/diagnose.command" diagnose.command >/dev/null 2>&1; then
  printf 'A genuine runtime-copy failure was suppressed\n' >&2
  exit 1
fi
grep -Fq 'preserve this destination' "$installed_runtime_bin/diagnose.command"
grep -Fq 'copy_project_runtime_file "$source_file" "$state/bin/$file"' \
  "$PROJECT_DIR/scripts/install_core.sh"
grep -Fq 'copy_project_runtime_file "$source_c" "$state/src/resolve_redirect.c"' \
  "$PROJECT_DIR/scripts/install_core.sh"

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
launcher_line="$(grep -nF 'if ! run_with_status "$launcher_phase"' \
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

# Restore the required entitlement so this signed fake app can seed updater fixtures.
/usr/libexec/PlistBuddy -c \
  'Set :com.apple.security.cs.disable-library-validation true' "$entitlements"
codesign --force --sign - --entitlements "$entitlements" \
  "$validation_app/Contents/MacOS/Resolve"

make_managed_install() {
  local root="$1" version="$2" app state launcher
  app="$root/$SUPPORT_RELATIVE/DaVinci Resolve $version.app"
  state="$root/$STATE_RELATIVE"
  launcher="$root/$APPS_RELATIVE/$LAUNCHER_NAME"
  mkdir -p "$root/$SUPPORT_RELATIVE/User" "$root/$SUPPORT_RELATIVE/User Preferences" \
    "$state/bin" "$state/src" "$launcher/Contents"
  ditto "$validation_app" "$app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
    "$app/Contents/Info.plist"
  printf '%s\n' "$root" > "$state/portable-root"
  printf '%s\n' "$app" > "$state/current-app"
  printf '%s\n' "$version" > "$state/version"
  printf 'old updater\n' > "$state/bin/runtime.txt"
  printf 'old source\n' > "$state/src/runtime.txt"
  printf 'old launcher\n' > "$launcher/Contents/runtime.txt"
  plutil -create xml1 "$launcher/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string io.github.MES30004E.davinci-resolve-portable \
    "$launcher/Contents/Info.plist"
}

printf 'Testing managed-install discovery and current-state validation...\n'
volumes_root="$TEST_ROOT/Fake Volumes"
single_root="$volumes_root/SSD One"
mkdir -p "$volumes_root"
make_managed_install "$single_root" 21.0.4
discovered=()
while IFS= read -r -d '' candidate; do discovered+=("$candidate"); done \
  < <(TMPDIR="$TEST_ROOT/tmp" discover_managed_installations "$volumes_root")
[[ "${#discovered[@]}" -eq 1 && "${discovered[0]}" == "$single_root" ]]
selected_single="$(TMPDIR="$TEST_ROOT/tmp" select_managed_installation "$volumes_root" 2>/dev/null)"
[[ "$selected_single" == "$single_root" ]]
[[ "$(current_install_version "$single_root")" == 21.0.4 ]]
TMPDIR="$TEST_ROOT/tmp" validate_managed_installation "$single_root"

guided_scan="$TEST_ROOT/Guided Volumes"
guided_root="$guided_scan/Only Portable"
guided_home="$TEST_ROOT/Guided Update Home"
mkdir -p "$guided_scan" "$guided_home/Library/Application Support" \
  "$guided_home/Library/Preferences"
make_managed_install "$guided_root" 21.0.4
guided_current_before="$(current_install_app "$guided_root")"
set +e
guided_output="$(HOME="$guided_home" DAVINCI_PORTABLE_HOME_OVERRIDE="$guided_home" \
  DAVINCI_PORTABLE_VOLUMES_ROOT="$guided_scan" DAVINCI_PORTABLE_NO_ANIMATION=1 \
  TMPDIR="$TEST_ROOT/tmp" "$PROJECT_DIR/Update Portable Resolve.command" "$fake_pkg" 2>&1)"
guided_status=$?
set -e
[[ "$guided_status" -ne 0 ]]
for expected_output in 'Portable Resolve installation found:' \
  'Version: 21.0.4' "App:     $guided_current_before" \
  'Verifying installer signature'; do
  if ! grep -Fq "$expected_output" <<<"$guided_output"; then
    printf 'Guided updater output did not contain: %s\n--- captured output ---\n%s\n' \
      "$expected_output" "$guided_output" >&2
    exit 1
  fi
done
[[ "$(current_install_app "$guided_root")" == "$guided_current_before" ]]
[[ "$(current_install_version "$guided_root")" == 21.0.4 ]]
[[ ! -e "$guided_home/Library/Application Support/Blackmagic Design" ]]
[[ ! -e "$guided_home/Library/Preferences/Blackmagic Design" ]]

second_root="$volumes_root/SSD Two/Resolve Portable"
make_managed_install "$second_root" 21.1
discovered=()
while IFS= read -r -d '' candidate; do discovered+=("$candidate"); done \
  < <(TMPDIR="$TEST_ROOT/tmp" discover_managed_installations "$volumes_root")
[[ "${#discovered[@]}" -eq 2 ]]
selected_multiple="$(printf '2\n' | TMPDIR="$TEST_ROOT/tmp" \
  select_managed_installation "$volumes_root" 2>/dev/null)"
[[ "$selected_multiple" == "${discovered[1]}" ]]

invalid_marker_root="$volumes_root/Invalid Marker"
make_managed_install "$invalid_marker_root" 21.0.4
printf '%s\n' "$single_root" > "$invalid_marker_root/$STATE_RELATIVE/portable-root"
if TMPDIR="$TEST_ROOT/tmp" validate_managed_installation "$invalid_marker_root"; then
  printf 'Marker pointing at another root was accepted\n' >&2
  exit 1
fi
malformed_marker_root="$volumes_root/Malformed Marker"
make_managed_install "$malformed_marker_root" 21.0.4
: > "$malformed_marker_root/$STATE_RELATIVE/portable-root"
if TMPDIR="$TEST_ROOT/tmp" validate_managed_installation "$malformed_marker_root"; then
  printf 'Malformed empty ownership marker was accepted\n' >&2
  exit 1
fi
missing_version_root="$volumes_root/Missing Version State"
make_managed_install "$missing_version_root" 21.0.4
rm "$missing_version_root/$STATE_RELATIVE/version"
if TMPDIR="$TEST_ROOT/tmp" validate_managed_installation "$missing_version_root"; then
  printf 'Installation with missing version state was accepted\n' >&2
  exit 1
fi

invalid_app_root="$volumes_root/Invalid Current App"
make_managed_install "$invalid_app_root" 21.0.4
printf '%s\n' "$TEST_ROOT/Outside Resolve.app" > "$invalid_app_root/$STATE_RELATIVE/current-app"
if TMPDIR="$TEST_ROOT/tmp" validate_managed_installation "$invalid_app_root"; then
  printf 'Current app outside the managed root was accepted\n' >&2
  exit 1
fi

empty_scan="$TEST_ROOT/Empty Volumes"
mkdir -p "$empty_scan"
fallback_selection="$(printf '%s\n' "$single_root" | TMPDIR="$TEST_ROOT/tmp" \
  select_managed_installation "$empty_scan" 2>/dev/null)"
[[ "$fallback_selection" == "$single_root" ]]

printf 'Testing comprehensive update backup and automatic rollback restoration...\n'
rollback_root="$TEST_ROOT/Rollback Portable Root"
make_managed_install "$rollback_root" 21.0.4
rollback_support="$rollback_root/$SUPPORT_RELATIVE"
rollback_state="$rollback_root/$STATE_RELATIVE"
rollback_launcher="$rollback_root/$APPS_RELATIVE/$LAUNCHER_NAME"
old_app="$(current_install_app "$rollback_root")"
mkdir -p "$rollback_support/Database" "$TEST_ROOT/Staged Support/Database" \
  "$TEST_ROOT/Staged Support/NewPayload"
printf 'old support\n' > "$rollback_support/Database/data.txt"
printf 'user database\n' > "$rollback_support/User/projects.db"
printf 'user preferences\n' > "$rollback_support/User Preferences/preferences.db"
rollback_dir="$rollback_state/rollback/update-20260810-160000"
rollback_backup_output="$(DAVINCI_PORTABLE_NO_ANIMATION=1 create_update_rollback \
  "$rollback_root" "$old_app" "$rollback_launcher" "$TEST_ROOT/Staged Support" "$rollback_dir")"
grep -Fq '= preserve  User/' <<<"$rollback_backup_output"
grep -Fq '= preserve  User Preferences/' <<<"$rollback_backup_output"
grep -Fq '> backup' <<<"$rollback_backup_output"
[[ -d "$rollback_dir/app/$(basename "$old_app")" ]]
[[ -f "$rollback_dir/state/current-app" ]]
[[ -f "$rollback_dir/launcher/$LAUNCHER_NAME/Contents/runtime.txt" ]]
[[ ! -e "$rollback_dir/support/User" && ! -e "$rollback_dir/support/User Preferences" ]]

new_app="$rollback_support/DaVinci Resolve 21.1.app"
ditto "$validation_app" "$new_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 21.1' "$new_app/Contents/Info.plist"
rm -rf "$old_app" "$rollback_support/Database"
mkdir -p "$rollback_support/Database" "$rollback_support/NewPayload"
printf 'new support\n' > "$rollback_support/Database/data.txt"
printf 'new payload\n' > "$rollback_support/NewPayload/data.txt"
rm -rf "$rollback_launcher"
mkdir -p "$rollback_launcher/Contents"
printf 'new launcher\n' > "$rollback_launcher/Contents/runtime.txt"
printf '%s\n' "$new_app" > "$rollback_state/current-app"
printf '21.1\n' > "$rollback_state/version"
printf 'new updater\n' > "$rollback_state/bin/runtime.txt"

TMPDIR="$TEST_ROOT/tmp" restore_update_rollback "$rollback_root" "$rollback_dir" "$new_app"
[[ -d "$old_app" && ! -e "$new_app" ]]
[[ "$(current_install_version "$rollback_root")" == 21.0.4 ]]
[[ "$(current_install_app "$rollback_root")" == "$old_app" ]]
grep -Fq 'old support' "$rollback_support/Database/data.txt"
[[ ! -e "$rollback_support/NewPayload" ]]
grep -Fq 'old launcher' "$rollback_launcher/Contents/runtime.txt"
grep -Fq 'old updater' "$rollback_state/bin/runtime.txt"
grep -Fq 'user database' "$rollback_support/User/projects.db"
grep -Fq 'user preferences' "$rollback_support/User Preferences/preferences.db"
TMPDIR="$TEST_ROOT/tmp" validate_managed_installation "$rollback_root"
[[ -d "$rollback_dir" ]]

printf 'Testing clean update-failure and rollback status output...\n'
source "$PROJECT_DIR/scripts/install_core.sh"
UPDATE_TRANSACTION_ROOT="$rollback_root"
UPDATE_ROLLBACK_DIR="$rollback_dir"
UPDATE_NEW_APP="$new_app"
UPDATE_TRANSACTION_ACTIVE=1
SUPPORT_TRANSACTION_ACTIVE=0
INSTALL_WORK_DIR=""
INCOMING_PATH=""
rollback_status_output="$(DAVINCI_PORTABLE_NO_ANIMATION=1 \
  TMPDIR="$TEST_ROOT/tmp" cleanup_install_work 2>&1)"
grep -Fq 'Update failed.' <<<"$rollback_status_output"
grep -Fq 'Restoring previous installation...' <<<"$rollback_status_output"
grep -Fq 'Previous installation restored successfully.' <<<"$rollback_status_output"
if [[ "$rollback_status_output" == *$'\r'* ]]; then
  printf 'Nonanimated rollback output contained terminal control animation\n' >&2
  exit 1
fi
TMPDIR="$TEST_ROOT/tmp" validate_managed_installation "$rollback_root"

rollback_failure_output="$(DAVINCI_PORTABLE_NO_ANIMATION=1 bash -c '
  source "$1/scripts/install_core.sh"
  UPDATE_TRANSACTION_ROOT="$2"
  UPDATE_ROLLBACK_DIR="$2/.davinci-resolve-portable/rollback/missing"
  UPDATE_NEW_APP="$2/Application Support/Blackmagic Design/DaVinci Resolve 99.app"
  UPDATE_TRANSACTION_ACTIVE=1
  SUPPORT_TRANSACTION_ACTIVE=0
  cleanup_install_work
' _ "$PROJECT_DIR" "$rollback_root" 2>&1)"
grep -Fq 'Update failed.' <<<"$rollback_failure_output"
grep -Fq 'Restoring previous installation...' <<<"$rollback_failure_output"
grep -Fq 'Automatic rollback failed.' <<<"$rollback_failure_output"
grep -Fq 'Rollback data retained:' <<<"$rollback_failure_output"
if [[ "$rollback_failure_output" == *$'\r'* ]]; then
  printf 'Nonanimated rollback-failure output contained terminal control animation\n' >&2
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

printf 'Auditing automated release workflow and friendly ZIP policy...\n'
release_workflow="$PROJECT_DIR/.github/workflows/release.yml"
grep -Fq -- "- 'v*.*.*'" "$release_workflow"
grep -Fq 'uses: actions/checkout@v6' "$release_workflow"
grep -A1 '^permissions:' "$release_workflow" | grep -Fq 'contents: read'
grep -A5 '^  release:' "$release_workflow" | grep -Fq 'contents: write'
grep -Fq 'GH_TOKEN: ${{ github.token }}' "$release_workflow"
grep -Fq 'sha256sum "${PACKAGE}.zip"' "$release_workflow"
grep -Fq -- '--generate-notes' "$release_workflow"
grep -Fq -- '--prerelease' "$release_workflow"
grep -Fq "if: contains(github.ref_name, '-')" "$release_workflow"
grep -Fq "if: \${{ !contains(github.ref_name, '-') }}" "$release_workflow"

release_body="$(sed -n '/cat > release-intro.md <<EOF/,/^[[:space:]]*EOF$/p' "$release_workflow")"
grep -Fq '## Install' <<<"$release_body"
grep -Fq 'Build Portable Resolve.command' <<<"$release_body"
grep -Fq 'Update Portable Resolve.command' <<<"$release_body"
grep -Fq 'See the README' <<<"$release_body"
grep -Fq '## Changes' <<<"$release_body"
for forbidden_heading in '## Tested configuration' '## Important' '## Downloads' \
  'DYLD' 'entitlement' 'Hardened Runtime' 'symlink'; do
  if grep -Fq "$forbidden_heading" <<<"$release_body"; then
    printf 'Release body contains an oversized technical section: %s\n' "$forbidden_heading" >&2
    exit 1
  fi
done

package_block="$(sed -n '/- name: Prepare release package/,/- name: Create friendly release introduction/p' \
  "$release_workflow")"
for required_asset in 'Build Portable Resolve.command' 'Update Portable Resolve.command' \
  'Uninstall.command' 'README.md' 'LICENSE' 'docs' 'scripts' 'src'; do
  grep -Fq "$required_asset" <<<"$package_block"
done
for forbidden_asset in 'known-good' 'CONTEXT.md' '.github' 'Resolve.icns' '*.pkg' '*.dmg' \
  '*.dylib' '*.app'; do
  if grep -Fq "$forbidden_asset" <<<"$package_block"; then
    printf 'Release package block includes forbidden content: %s\n' "$forbidden_asset" >&2
    exit 1
  fi
done

printf 'All safe workspace-only tests passed.\n'
