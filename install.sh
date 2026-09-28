#!/usr/bin/env bash
# Builds DisplayManager in Release mode and installs it to /Applications/DisplayManager.app.
#
# Usage: ./install.sh [--no-launch] [--help]
#
#   --no-launch   install only, do not start the app afterwards
#
# Never uses sudo, never installs Homebrew or displayplacer, and changes nothing outside
# /Applications/DisplayManager.app and the build folder (~/Library/Caches/DisplayManager-build).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_NAME="DisplayManager"
BUNDLE_ID="com.bachana.DisplayManager"
INSTALL_DIR="/Applications"
TARGET="$INSTALL_DIR/$APP_NAME.app"
STAGING="$INSTALL_DIR/.$APP_NAME.app.installing"
PREVIOUS="$INSTALL_DIR/.$APP_NAME.app.previous"
BUILD_DIR="${DM_BUILD_DIR:-$HOME/Library/Caches/DisplayManager-build}"
BUILT_APP="$BUILD_DIR/dist/$APP_NAME.app"

LAUNCH=1
for argument in "$@"; do
    case "$argument" in
        --no-launch) LAUNCH=0 ;;
        -h|--help)
            sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown option '$argument' (see ./install.sh --help)" >&2
            exit 64
            ;;
    esac
done

step() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
    # Leftovers from an interrupted install. The installed app is never removed here.
    rm -rf "$STAGING" 2>/dev/null || true
    if [[ -d "$PREVIOUS" && ! -e "$TARGET" ]]; then
        mv "$PREVIOUS" "$TARGET" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 1. Prerequisites
step "Checking prerequisites"
[[ "$(uname -s)" == "Darwin" ]] || fail "DisplayManager runs on macOS only."
macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
if [[ ! "$macos_major" =~ ^[0-9]+$ ]] || (( macos_major < 14 )); then
    fail "macOS 14 or newer is required (this Mac has $macos_version)."
fi
for tool in codesign plutil ditto pgrep; do
    command -v "$tool" >/dev/null 2>&1 || fail "the required tool '$tool' was not found."
done

# shellcheck source=Scripts/toolchain.sh
source "$ROOT_DIR/Scripts/toolchain.sh"
if ! dm_select_toolchain; then
    dm_print_toolchain_help
    exit 1
fi
echo "    Swift: $DM_SWIFT_VERSION"

# iCloud Drive can keep files only in the cloud ("Optimize Mac Storage"); the build needs them locally.
evicted="$(find "$ROOT_DIR/Sources" "$ROOT_DIR/Packaging" "$ROOT_DIR/Scripts" -name '.*.icloud' -print -quit 2>/dev/null || true)"
if [[ -n "$evicted" ]]; then
    fail "some project files are only in iCloud. Download them first (Finder: right-click the folder › Download Now), then run ./install.sh again."
fi

# 2. /Applications must be writable without sudo.
if [[ ! -w "$INSTALL_DIR" ]]; then
    fail "$INSTALL_DIR is not writable for $(id -un). This installer does not use sudo. Use an administrator account, or copy the app built by Scripts/build-app.sh into $INSTALL_DIR yourself."
fi
if [[ -e "$TARGET" ]]; then
    # Folders owned by another user (for example root) cannot be emptied without sudo.
    foreign="$(find "$TARGET" -type d ! -user "$(id -u)" -print -quit 2>/dev/null || true)"
    if [[ -n "$foreign" ]]; then
        fail "$TARGET contains folders owned by another user, so it cannot be replaced without sudo. Move it to the Trash in Finder (it may ask for an administrator password), then run ./install.sh again."
    fi
fi

# 3. displayplacer (only checked, never installed)
displayplacer_path=""
if found="$(command -v displayplacer 2>/dev/null)"; then
    displayplacer_path="$found"
else
    for candidate in /opt/homebrew/bin/displayplacer /usr/local/bin/displayplacer; do
        if [[ -x "$candidate" ]]; then
            displayplacer_path="$candidate"
            break
        fi
    done
fi
if [[ -n "$displayplacer_path" ]]; then
    displayplacer_version="$("$displayplacer_path" --version 2>/dev/null | head -n 1 || true)"
    echo "    displayplacer: $displayplacer_path${displayplacer_version:+ ($displayplacer_version)}"
else
    cat >&2 <<'EOF'
warning: displayplacer was not found. DisplayManager needs it to read and apply layouts.
         Install it with Homebrew, then click Re-check in DisplayManager › Settings › displayplacer:
             brew install displayplacer
         The installation continues. The app shows the missing dependency until it is installed.
EOF
fi

# 4. Build
step "Building Release"
DM_BUILD_DIR="$BUILD_DIR" "$ROOT_DIR/Scripts/build-app.sh" release
[[ -x "$BUILT_APP/Contents/MacOS/$APP_NAME" ]] || fail "the build did not produce $BUILT_APP."

# 5. Quit a running copy. Layouts and settings are saved on every change, so nothing is lost.
running_pids() {
    local pid path
    for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
        path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        [[ "$path" == *"/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]] && echo "$pid"
    done
    return 0
}
pids="$(running_pids)"
if [[ -n "$pids" ]]; then
    step "Quitting the running DisplayManager"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    for _ in $(seq 1 50); do
        [[ -z "$(running_pids)" ]] && break
        sleep 0.1
    done
    pids="$(running_pids)"
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
        sleep 1
        [[ -z "$(running_pids)" ]] || fail "DisplayManager is still running. Quit it from its menu, then run ./install.sh again."
    fi
fi

# 6. Replace safely: copy next to the target, verify, then swap.
step "Installing to $TARGET"
rm -rf "$STAGING" "$PREVIOUS"
ditto "$BUILT_APP" "$STAGING"
codesign --verify --strict "$STAGING" || fail "the copied app failed signature verification. The existing app was not changed."
if [[ -e "$TARGET" ]]; then
    mv "$TARGET" "$PREVIOUS"
fi
if ! mv "$STAGING" "$TARGET"; then
    [[ -d "$PREVIOUS" ]] && mv "$PREVIOUS" "$TARGET"
    fail "could not move the new app into place. The previous version was restored."
fi
rm -rf "$PREVIOUS"

# 7. Verify the installed bundle.
step "Verifying"
[[ -x "$TARGET/Contents/MacOS/$APP_NAME" ]] || fail "the installed executable is missing or not executable."
codesign --verify --strict --verbose=1 "$TARGET" 2>&1 | sed 's/^/    /'
installed_id="$(plutil -extract CFBundleIdentifier raw -o - "$TARGET/Contents/Info.plist")"
[[ "$installed_id" == "$BUNDLE_ID" ]] || fail "unexpected bundle identifier '$installed_id'."
installed_version="$(plutil -extract CFBundleShortVersionString raw -o - "$TARGET/Contents/Info.plist")"
echo "    $APP_NAME $installed_version ($installed_id), ad-hoc signed"

# 8. Launch
step "Installed $TARGET"
if (( LAUNCH )); then
    open "$TARGET"
    echo "    DisplayManager is running. Look for its icon in the menu bar."
else
    echo "    Start it with: open \"$TARGET\""
fi
