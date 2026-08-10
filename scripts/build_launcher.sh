#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

[[ $# -eq 3 ]] || die "Usage: $0 <real-resolve-app> <launcher-app> <source-icon>"
real_app="$1"; launcher="$2"; source_icon="$3"
executable="$real_app/Contents/MacOS/Resolve"
dylib="$real_app/Contents/Frameworks/$DYLIB_NAME"
[[ -x "$executable" ]] || die "Resolve executable not found: $executable"
[[ -f "$dylib" ]] || die "Redirect dylib not found: $dylib"
[[ -f "$source_icon" ]] || die "Resolve.icns not found in extracted official app."

require_macos
require_command osacompile
work="$(mktemp -d "${TMPDIR:-/tmp}/resolve-launcher.XXXXXX")"
trap 'rm -rf "$work"' EXIT
source_file="$work/launcher.applescript"
staged_launcher="$work/$LAUNCHER_NAME"

escape_applescript() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
escaped_executable="$(escape_applescript "$executable")"
escaped_dylib="$(escape_applescript "$dylib")"

printf '%s\n' \
  "set resolveExecutable to \"$escaped_executable\"" \
  "set redirectLibrary to \"$escaped_dylib\"" \
  'do shell script "DYLD_INSERT_LIBRARIES=" & quoted form of redirectLibrary & " " & quoted form of resolveExecutable & " >/dev/null 2>&1 &"' \
  > "$source_file"

osacompile -o "$staged_launcher" "$source_file"
plist="$staged_launcher/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$plist" >/dev/null 2>&1 || true
for pair in \
  'CFBundleIconFile:Resolve.icns' \
  'CFBundleName:DaVinci Resolve' \
  'CFBundleDisplayName:DaVinci Resolve' \
  'CFBundleIdentifier:io.github.MES30004E.davinci-resolve-portable' \
  'NSRemovableVolumesUsageDescription:DaVinci Resolve Portable needs access to its application and support files stored on this external drive.'
do
  key="${pair%%:*}"; value="${pair#*:}"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
done
cp "$source_icon" "$staged_launcher/Contents/Resources/Resolve.icns"
plutil -lint "$plist" >/dev/null

# Bundle edits are complete. This must remain the final mutation before copy.
codesign --force --sign - "$staged_launcher"
codesign --verify --strict "$staged_launcher"

mkdir -p "$(dirname "$launcher")"
replacement="$launcher.new.$$"
rm -rf "$replacement"
COPYFILE_DISABLE=1 ditto "$staged_launcher" "$replacement"
codesign --verify --strict "$replacement"
if [[ -e "$launcher" || -L "$launcher" ]]; then
  old="$launcher.old.$$"
  mv "$launcher" "$old"
  if mv "$replacement" "$launcher"; then
    rm -rf "$old"
  else
    mv "$old" "$launcher"
    die "Could not install launcher; the previous launcher was restored."
  fi
else
  mv "$replacement" "$launcher"
fi
info "Created launcher: $launcher"
