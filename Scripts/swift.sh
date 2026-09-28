#!/usr/bin/env bash
# Runs a SwiftPM command for this package with the same toolchain selection as the build script.
#
# Usage: Scripts/swift.sh <swift arguments>
# Examples:
#   Scripts/swift.sh test
#   Scripts/swift.sh build -c release -Xswiftc -warnings-as-errors
#
# Build products go to $DM_BUILD_DIR/swiftpm (default ~/Library/Caches/DisplayManager-build/swiftpm).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=toolchain.sh
source "$SCRIPT_DIR/toolchain.sh"

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

BUILD_DIR="${DM_BUILD_DIR:-$HOME/Library/Caches/DisplayManager-build}"
if ! dm_select_toolchain; then
    dm_print_toolchain_help
    exit 1
fi
mkdir -p "$BUILD_DIR"
dm_prepare_package_api_libs "$BUILD_DIR" >&2

subcommand="$1"
shift
exec "$DM_SWIFT" "$subcommand" --package-path "$ROOT_DIR" --scratch-path "$BUILD_DIR/swiftpm" "$@"
