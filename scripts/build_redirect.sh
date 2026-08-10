#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/common.sh"

[[ $# -eq 2 ]] || die "Usage: $0 <portable-support-directory> <output-dylib>"
destination="$1"
output="$2"
[[ "$destination" == /* ]] || die "Redirect destination must be absolute."
[[ "$destination" != *$'\n'* && "$destination" != *$'\r'* ]] || die "Redirect destination may not contain newlines."

require_macos
require_command xcrun
mkdir -p "$(dirname "$output")"

# Encode the path as a C string literal without eval or generated source files.
escaped="${destination//\\/\\\\}"
escaped="${escaped//\"/\\\"}"
definition="-DRESOLVE_REDIRECT_DESTINATION=\"$escaped\""

xcrun clang -arch arm64 -dynamiclib -Wall -Wextra -Werror \
  "$definition" \
  "$PROJECT_DIR/src/resolve_redirect.c" -o "$output"
codesign --force --sign - "$output"
file "$output" | grep -q 'arm64' || die "Redirect dylib is not arm64."
codesign --verify --strict "$output"
info "Built and signed redirector: $output"
