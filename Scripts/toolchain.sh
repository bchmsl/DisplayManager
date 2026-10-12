# Shared helpers for build-app.sh, swift.sh, generate-icon.sh and install.sh. Source this file, do not run it.
#
# dm_select_toolchain picks a Swift 6 toolchain and macOS SDK that can build the app, for the current script
# process only. Candidates, first match wins:
#   1. the active developer directory (DEVELOPER_DIR or `xcode-select -p`);
#   2. Xcode apps in /Applications and ~/Applications;
#   3. the Command Line Tools.
# Each candidate is tried with its default macOS SDK first. The macOS 27 SDK declares SwiftUI's @State as a macro
# whose plugin ships only with Xcode, so the Command Line Tools cannot build SwiftUI views with it. For such a
# candidate the second pass uses its previous macOS SDK instead, which the Command Line Tools install alongside.
#
# On success it exports DEVELOPER_DIR (and SDKROOT for a fallback SDK) and sets DM_SWIFT, DM_SWIFT_VERSION,
# DM_DEVELOPER_DIR, DM_SDK_PATH, DM_SDK_VERSION, plus DM_TOOLCHAIN_NOTE when a fallback SDK is used.
# On failure DM_TOOLCHAIN_REASONS says why each candidate was skipped. It never changes system settings and never
# uses sudo.

DM_CLT_DIR="/Library/Developer/CommandLineTools"

dm_swift_major_version() {
    # Prints the major version from `swift --version` output, or nothing.
    sed -n 's/.*Swift version \([0-9][0-9]*\)\..*/\1/p' | head -n 1
}

dm_swift6_version() {
    # Prints the first line of `<command> --version` when it is Swift 6 or newer, fails otherwise.
    local output major
    output="$("$@" --version 2>/dev/null)" || return 1
    major="$(printf '%s\n' "$output" | dm_swift_major_version)"
    [[ -n "$major" && "$major" -ge 6 ]] || return 1
    printf '%s\n' "$output" | head -n 1
}

dm_candidate_developer_dirs() {
    # Prints the developer directories to try, one per line, in order. Duplicates are removed by the caller.
    local active app
    active="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
    if [[ -n "$active" ]]; then
        printf '%s\n' "$active"
    fi
    for app in /Applications/Xcode.app /Applications/Xcode*.app "$HOME/Applications/Xcode.app" "$HOME/Applications"/Xcode*.app; do
        if [[ -d "$app/Contents/Developer" ]]; then
            printf '%s\n' "$app/Contents/Developer"
        fi
    done
    printf '%s\n' "$DM_CLT_DIR"
}

dm_resolve_developer_dir() {
    # Prints the physical path of a developer directory. An Xcode app path becomes its Contents/Developer, as
    # xcode-select does. Fails when the directory does not exist.
    local resolved
    resolved="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    if [[ "$resolved" == *.app && -d "$resolved/Contents/Developer" ]]; then
        resolved="$resolved/Contents/Developer"
    fi
    printf '%s\n' "$resolved"
}

dm_sdk_version() {
    # Prints an SDK's version, for example 26.5, or nothing.
    plutil -extract Version raw -o - "$1/SDKSettings.plist" 2>/dev/null || true
}

dm_sdk_declares_state_macro() {
    # Succeeds when the SDK declares SwiftUI's @State as a macro (macOS 27 SDK and newer).
    local file
    for file in "$1"/System/Library/Frameworks/SwiftUI.framework/Modules/*.swiftmodule/*.swiftinterface \
        "$1"/System/Library/Frameworks/SwiftUICore.framework/Modules/*.swiftmodule/*.swiftinterface; do
        [[ -f "$file" ]] || continue
        if grep -q -E 'public macro State(<|\()' "$file"; then
            return 0
        fi
    done
    return 1
}

dm_has_swiftui_macros() {
    # Succeeds when SwiftUI's macro plugin is found where the compiler looks for it: next to the SDK's platform
    # (Xcode has it in MacOSX.platform; the Command Line Tools do not have it) or in the toolchain.
    local sdk="$1" swift_bin_dir="$2" plugins
    for plugins in "$sdk/../../usr/lib/swift/host/plugins" \
        "$sdk/../../usr/local/lib/swift/host/plugins" \
        "$swift_bin_dir/../lib/swift/host/plugins" \
        "$swift_bin_dir/../local/lib/swift/host/plugins"; do
        if [[ -e "$plugins/libSwiftUIMacros.dylib" ]]; then
            return 0
        fi
    done
    return 1
}

dm_can_build_swiftui() {
    # Arguments: SDK path, directory of the swift executable.
    ! dm_sdk_declares_state_macro "$1" || dm_has_swiftui_macros "$1" "$2"
}

dm_fallback_sdks() {
    # Prints the other macOS SDKs of a developer directory, newest first. Only real directories (the version
    # aliases are links) of the default SDK's major version or the one before are used: older SDKs left over from
    # previous installs may not work with the current compiler.
    local developer_dir="$1" default_major="$2" sdk version major minor
    for sdk in "$developer_dir"/SDKs/MacOSX*.sdk "$developer_dir"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk; do
        [[ -d "$sdk" && ! -L "$sdk" ]] || continue
        version="$(dm_sdk_version "$sdk")"
        major="${version%%.*}"
        minor="${version#"$major"}"
        minor="${minor#.}"
        minor="${minor%%.*}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
        (( 10#$major >= 14 && 10#$major >= default_major - 1 )) || continue
        printf '%04d%04d\t%s\n' "$((10#$major))" "$((10#$minor))" "$sdk"
    done | sort -r | cut -f 2-
}

dm_add_reason() {
    DM_TOOLCHAIN_REASONS="${DM_TOOLCHAIN_REASONS}  - $1"$'\n'
}

dm_use_toolchain() {
    # Arguments: developer dir, swift path, swift version line, SDK path, "fallback" to export SDKROOT.
    export DEVELOPER_DIR="$1"
    DM_DEVELOPER_DIR="$1"
    DM_SWIFT="$2"
    DM_SWIFT_VERSION="$3"
    DM_SDK_PATH="$4"
    DM_SDK_VERSION="$(dm_sdk_version "$4")"
    if [[ "${5:-}" == "fallback" ]]; then
        export SDKROOT="$4"
    fi
}

dm_select_toolchain() {
    DM_SWIFT=""
    DM_SWIFT_VERSION=""
    DM_DEVELOPER_DIR=""
    DM_SDK_PATH=""
    DM_SDK_VERSION=""
    DM_TOOLCHAIN_NOTE=""
    DM_TOOLCHAIN_REASONS=""
    if ! command -v xcrun >/dev/null 2>&1; then
        dm_add_reason "xcrun was not found"
        return 1
    fi

    local active active_real="" candidates dir real seen="|" swift version sdk sdk_version blocked=""
    active="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
    if [[ -n "$active" ]]; then
        active_real="$(dm_resolve_developer_dir "$active" || true)"
    fi
    candidates="$(dm_candidate_developer_dirs)"

    # Pass 1: each candidate with its default SDK. SDKROOT is removed while probing, because xcrun fails for every
    # tool when it points to a missing SDK.
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if ! real="$(dm_resolve_developer_dir "$dir")"; then
            dm_add_reason "$dir: does not exist"
            continue
        fi
        case "$seen" in *"|$real|"*) continue ;; esac
        seen="$seen$real|"

        if ! swift="$(env -u SDKROOT DEVELOPER_DIR="$real" xcrun --find swift 2>/dev/null)" || [[ ! -x "$swift" ]] \
            || ! version="$(dm_swift6_version env -u SDKROOT DEVELOPER_DIR="$real" xcrun swift)"; then
            if [[ -d "$real/Platforms" ]]; then
                dm_add_reason "$real: no working Swift 6 (if its license is not accepted yet: sudo xcodebuild -license accept)"
            else
                dm_add_reason "$real: no working Swift 6"
            fi
            continue
        fi

        # A preset SDKROOT is kept only for the active directory, and only when it exists.
        if [[ "$real" == "$active_real" && -n "${SDKROOT:-}" && -d "$SDKROOT" ]]; then
            sdk="$SDKROOT"
        else
            sdk="$(env -u SDKROOT DEVELOPER_DIR="$real" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
        fi
        if [[ -z "$sdk" || ! -d "$sdk" ]]; then
            dm_add_reason "$real: no macOS SDK${sdk:+ at $sdk}"
            continue
        fi

        if ! dm_can_build_swiftui "$sdk" "$(dirname "$swift")"; then
            sdk_version="$(dm_sdk_version "$sdk")"
            if [[ -d "$real/Platforms/MacOSX.platform" ]]; then
                dm_add_reason "$real: SwiftUI's macros were not found for the SDK at $sdk"
            else
                dm_add_reason "$real: the macOS ${sdk_version:-?} SDK needs SwiftUI macros that only Xcode has"
            fi
            blocked="$blocked$real"$'\t'"$swift"$'\t'"$version"$'\t'"$sdk"$'\n'
            continue
        fi

        if [[ "$sdk" != "${SDKROOT:-}" ]]; then
            unset SDKROOT
        fi
        dm_use_toolchain "$real" "$swift" "$version" "$sdk"
        return 0
    done <<< "$candidates"

    # Pass 2: a blocked candidate with an older SDK of its own whose SwiftUI does not need the macros.
    local default_version default_major fallback found
    while IFS=$'\t' read -r real swift version sdk; do
        [[ -n "$real" ]] || continue
        default_version="$(dm_sdk_version "$sdk")"
        default_major="${default_version%%.*}"
        if [[ ! "$default_major" =~ ^[0-9]+$ ]]; then
            continue
        fi
        found=""
        while IFS= read -r fallback; do
            [[ -n "$fallback" ]] || continue
            [[ "$fallback" -ef "$sdk" ]] && continue
            if dm_can_build_swiftui "$fallback" "$(dirname "$swift")"; then
                found="$fallback"
                break
            fi
        done <<< "$(dm_fallback_sdks "$real" "$((10#$default_major))")"
        if [[ -z "$found" ]]; then
            dm_add_reason "$real: no other macOS $((10#$default_major - 1)) or $((10#$default_major)) SDK to fall back to"
            continue
        fi
        dm_use_toolchain "$real" "$swift" "$version" "$found" fallback
        if [[ -d "$real/Platforms/MacOSX.platform" ]]; then
            DM_TOOLCHAIN_NOTE="The SDK at $sdk cannot build SwiftUI with this toolchain, so $found is used."
        else
            DM_TOOLCHAIN_NOTE="The macOS ${default_version} SDK needs Xcode for SwiftUI, so the macOS ${DM_SDK_VERSION} SDK from $real is used. Installing Xcode removes this fallback."
        fi
        return 0
    done <<< "$blocked"
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
    {
        echo "No Swift 6 toolchain that can build DisplayManager was found."
        if [[ -n "${DM_TOOLCHAIN_REASONS:-}" ]]; then
            echo
            echo "Checked:"
            printf '%s' "$DM_TOOLCHAIN_REASONS"
        fi
        cat <<'EOF'

Fix one of these, then run the command again:
  - Install Xcode from the App Store (recommended). If it is installed, accept its license once:
        sudo xcodebuild -license accept
  - Or install the Command Line Tools:   xcode-select --install
    They build with their previous macOS SDK, because the macOS 27 SDK needs Xcode for SwiftUI.
EOF
    } >&2
}
