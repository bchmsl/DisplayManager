#!/usr/bin/env bash
# Regenerates Packaging/AppIcon.icns from Scripts/generate-icon.swift.
#
# Usage: Scripts/generate-icon.sh
# The generated icon is kept in the repository, so installing does not need this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=toolchain.sh
source "$SCRIPT_DIR/toolchain.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: iconutil was not found" >&2
    exit 1
fi
if ! dm_select_toolchain; then
    dm_print_toolchain_help
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/DisplayManager-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/AppIcon.iconset"

"$DM_SWIFT" "$SCRIPT_DIR/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$WORK_DIR/AppIcon.icns"
mv "$WORK_DIR/AppIcon.icns" "$ROOT_DIR/Packaging/AppIcon.icns"
echo "==> Wrote $ROOT_DIR/Packaging/AppIcon.icns"
