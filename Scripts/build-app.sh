#!/usr/bin/env bash
# Builds DisplayManager.app from the Swift package.
#
# Usage: Scripts/build-app.sh [release|debug]
#
# Output: $DM_BUILD_DIR/dist/DisplayManager.app
# DM_BUILD_DIR defaults to ~/Library/Caches/DisplayManager-build, so build products stay out of the
# source folder (which may live in iCloud Drive).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=toolchain.sh
source "$SCRIPT_DIR/toolchain.sh"

APP_NAME="DisplayManager"
BUNDLE_ID="com.bachana.DisplayManager"
VERSION="1.0.0"

CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    release|debug) ;;
    -h|--help)
        sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "error: unknown configuration '$CONFIGURATION' (use release or debug)" >&2
        exit 64
        ;;
esac

BUILD_DIR="${DM_BUILD_DIR:-$HOME/Library/Caches/DisplayManager-build}"
SCRATCH_DIR="$BUILD_DIR/swiftpm"
DIST_DIR="$BUILD_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
STAGING_DIR="$DIST_DIR/.$APP_NAME.app.staging"

for tool in plutil codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' was not found" >&2
        exit 1
    fi
done

if ! dm_select_toolchain; then
    dm_print_toolchain_help
    exit 1
fi
echo "==> Using $DM_SWIFT_VERSION, macOS $DM_SDK_VERSION SDK"
if [[ -n "$DM_TOOLCHAIN_NOTE" ]]; then
    echo "==> Note: $DM_TOOLCHAIN_NOTE"
fi
mkdir -p "$BUILD_DIR"
dm_prepare_package_api_libs "$BUILD_DIR"

ICON_FILE="$ROOT_DIR/Packaging/AppIcon.icns"
PLIST_TEMPLATE="$ROOT_DIR/Packaging/Info.plist"
if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    echo "error: missing $PLIST_TEMPLATE" >&2
    exit 1
fi
if [[ ! -f "$ICON_FILE" ]]; then
    echo "error: missing $ICON_FILE (generate it with Scripts/generate-icon.sh)" >&2
    exit 1
fi

echo "==> Building $APP_NAME ($CONFIGURATION)"
SWIFT_BUILD=("$DM_SWIFT" build
    --package-path "$ROOT_DIR"
    --scratch-path "$SCRATCH_DIR"
    -c "$CONFIGURATION"
    --product "$APP_NAME")
"${SWIFT_BUILD[@]}"
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: build did not produce $EXECUTABLE" >&2
    exit 1
fi

echo "==> Assembling bundle"
mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Contents/MacOS" "$STAGING_DIR/Contents/Resources"
cp "$EXECUTABLE" "$STAGING_DIR/Contents/MacOS/$APP_NAME"
chmod 755 "$STAGING_DIR/Contents/MacOS/$APP_NAME"
cp "$ICON_FILE" "$STAGING_DIR/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGING_DIR/Contents/PkgInfo"

BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$PLIST_TEMPLATE" > "$STAGING_DIR/Contents/Info.plist"
plutil -lint "$STAGING_DIR/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
codesign --force --sign - --options runtime --timestamp=none "$STAGING_DIR"
codesign --verify --strict --verbose=2 "$STAGING_DIR" 2>&1 | sed 's/^/    /'

rm -rf "$APP_DIR"
mv "$STAGING_DIR" "$APP_DIR"
echo "==> Built $APP_DIR"
