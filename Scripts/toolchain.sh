# Shared helpers for build-app.sh and install.sh. Source this file, do not run it.
#
# dm_select_toolchain picks a working Swift 6 toolchain for the current script process only:
#   1. the active developer directory (`xcrun swift`), when it works;
#   2. otherwise the Command Line Tools, via DEVELOPER_DIR for this process.
# It never changes system settings and never uses sudo.
# On success it sets DM_SWIFT (the swift executable) and DM_SWIFT_VERSION.

DM_CLT_DIR="/Library/Developer/CommandLineTools"

dm_swift_major_version() {
    # Prints the major version from `swift --version` output, or nothing.
    sed -n 's/.*Swift version \([0-9][0-9]*\)\..*/\1/p' | head -n 1
}

dm_try_swift() {
    local output major
    output="$("$@" --version 2>/dev/null)" || return 1
    major="$(printf '%s\n' "$output" | dm_swift_major_version)"
    [[ -n "$major" && "$major" -ge 6 ]] || return 1
    DM_SWIFT_VERSION="$(printf '%s\n' "$output" | head -n 1)"
    return 0
}

dm_select_toolchain() {
    DM_SWIFT=""
    DM_SWIFT_VERSION=""
    if command -v xcrun >/dev/null 2>&1; then
        local found
        if found="$(xcrun --find swift 2>/dev/null)" && [[ -x "$found" ]] && dm_try_swift xcrun swift; then
            DM_SWIFT="$found"
            return 0
        fi
    fi
    if [[ -x "$DM_CLT_DIR/usr/bin/swift" ]] && DEVELOPER_DIR="$DM_CLT_DIR" dm_try_swift "$DM_CLT_DIR/usr/bin/swift"; then
        export DEVELOPER_DIR="$DM_CLT_DIR"
        DM_SWIFT="$DM_CLT_DIR/usr/bin/swift"
        return 0
    fi
    return 1
}

# Some Command Line Tools installs keep stale `*.private.swiftinterface` files from an older Swift next to a
# newer PackageDescription library. The compiler prefers the private interface, so the manifest then fails to
# link ("Undefined symbols ... Package.__allocating_init"). When that mismatch is detected, this builds a mirror
# of the package API libraries without the stale files inside the build directory and points SwiftPM at it with
# SWIFTPM_CUSTOM_LIBS_DIR. Nothing outside the build directory is changed.
dm_prepare_package_api_libs() {
    local build_dir="$1"
    local swift_bin_dir pm_dir interface private_interface public_version private_version
    swift_bin_dir="$(dirname "$DM_SWIFT")"
    pm_dir="$(cd "$swift_bin_dir/../lib/swift/pm" 2>/dev/null && pwd -P)" || return 0
    interface="$pm_dir/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface"
    private_interface="$pm_dir/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface"
    [[ -f "$interface" && -f "$private_interface" ]] || return 0
    public_version="$(grep -m 1 'swift-compiler-version' "$interface" || true)"
    private_version="$(grep -m 1 'swift-compiler-version' "$private_interface" || true)"
    [[ "$public_version" != "$private_version" ]] || return 0

    local mirror="$build_dir/package-api-libs"
    rm -rf "$mirror"
    local api entry module file
    for api in ManifestAPI PluginAPI; do
        [[ -d "$pm_dir/$api" ]] || continue
        mkdir -p "$mirror/$api"
        for entry in "$pm_dir/$api"/*; do
            if [[ -d "$entry" && "$entry" == *.swiftmodule ]]; then
                module="$mirror/$api/$(basename "$entry")"
                mkdir -p "$module"
                for file in "$entry"/*; do
                    [[ "$file" == *.private.swiftinterface ]] && continue
                    ln -s "$file" "$module/$(basename "$file")"
                done
            else
                ln -s "$entry" "$mirror/$api/$(basename "$entry")"
            fi
        done
    done
    export SWIFTPM_CUSTOM_LIBS_DIR="$mirror"
    echo "==> Note: ignoring stale package API interfaces in $pm_dir (see Scripts/toolchain.sh)"
}

dm_print_toolchain_help() {
    cat >&2 <<'EOF'
No working Swift 6 toolchain was found.

Fix one of these, then run the command again:
  - Install the Command Line Tools:      xcode-select --install
  - Or, if Xcode is installed, accept its license once:  sudo xcodebuild -license accept
EOF
}
