#!/bin/bash
# swift-clt-plugins.sh — keep swift builds working under Command Line Tools.
#
# The macOS 26 SDK implements SwiftUI @State and #Preview as external Swift
# macros. The macro plugin dylibs (libSwiftUIMacros, libPreviewsMacros) ship
# only inside full Xcode, not in CLT, so `swift build` / `swift test` under
# CLT die with "plugin for module 'SwiftUIMacros' not found". When the active
# developer directory is CLT, this script prints the -Xswiftc -plugin-path
# flags Swift needs, resolved from one of:
#
#   1. Vendor/SwiftMacroPlugins/   — stash copied from a previously installed
#      Xcode (`scripts/swift-clt-plugins.sh refresh`). Gitignored: Apple
#      binaries cannot be redistributed in a public repo.
#   2. /Applications/Xcode.app     — the live plugin dir of an installed Xcode.
#
# With full Xcode selected as developer dir the script prints nothing and
# builds behave exactly as before.
#
# Usage:
#   scripts/swift-clt-plugins.sh flags     print extra swift flags (may be empty)
#   scripts/swift-clt-plugins.sh refresh   copy plugin dylibs from Xcode into Vendor
#   scripts/swift-clt-plugins.sh check      print status, exit 0 if buildable
#
# Sourcing is not needed; build.sh, Makefile and bundle_app.sh capture stdout.

set -euo pipefail

# Resolve repo root from this script's location so the flags we print are
# absolute: SwiftBuild compiles with a working directory that differs from the
# repo root, which would break a relative plugin path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDORED_DIR="$REPO_ROOT/Vendor/SwiftMacroPlugins"
XCODE_PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
DYLIBS=(libSwiftUIMacros.dylib libPreviewsMacros.dylib)

# CLT's own plugin dir. Apple does not ship the SwiftUI macro plugins there
# today; if a future CLT does, the flags become unnecessary and this helper
# goes silent on its own.
CLT_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins"

clt_has_plugins() {
    local i
    for i in "${DYLIBS[@]}"; do
        [ -f "$CLT_PLUGINS/$i" ] || return 1
    done
    return 0
}

# The stub at /usr/bin/actool exists under CLT too, so resolve the real
# developer dir the way swift-frontend does.
active_developer_dir() {
    if [ -n "${DEVELOPER_DIR:-}" ]; then
        printf '%s\n' "$DEVELOPER_DIR"
    else
        xcode-select -p
    fi
}

is_clt() {
    [ "$(active_developer_dir)" = "/Library/Developer/CommandLineTools" ]
}

# Prefer the vendored stash over live Xcode: it keeps working after Xcode is
# deleted, which is the whole point of stashing.
plugin_source_dir() {
    local i
    for i in "${DYLIBS[@]}"; do
        [ -f "$VENDORED_DIR/$i" ] || { [ -d "$XCODE_PLUGINS" ] && printf '%s\n' "$XCODE_PLUGINS" && return 0; return 1; }
    done
    printf '%s\n' "$VENDORED_DIR"
}

cmd_flags() {
    is_clt || return 0
    clt_has_plugins && return 0
    local dir
    if ! dir="$(plugin_source_dir)"; then
        echo "error: building under Command Line Tools needs the SwiftUI macro plugins" >&2
        echo "  (libSwiftUIMacros.dylib, libPreviewsMacros.dylib), which ship only in Xcode." >&2
        echo "  Fix: install Xcode, or run scripts/swift-clt-plugins.sh refresh while it is" >&2
        echo "  still installed to stash the dylibs in $VENDORED_DIR." >&2
        return 1
    fi
    printf -- '-Xswiftc -plugin-path -Xswiftc %s\n' "$dir"
}

cmd_refresh() {
    if [ ! -d "$XCODE_PLUGINS" ]; then
        echo "error: no Xcode at $XCODE_PLUGINS — nothing to refresh from" >&2
        exit 1
    fi
    mkdir -p "$VENDORED_DIR"
    local i
    for i in "${DYLIBS[@]}"; do
        cp "$XCODE_PLUGINS/$i" "$VENDORED_DIR/$i"
        echo "  stashed $VENDORED_DIR/$i"
    done
    echo "Note: the stash is version-locked to the current SDK. Re-run refresh" >&2
    echo "after any macOS SDK / CLT update, or builds may fail with macro errors." >&2
}

cmd_check() {
    if ! is_clt; then
        echo "developer dir: $(active_developer_dir) (full toolchain, no plugin flags needed)"
        exit 0
    fi
    echo "developer dir: Command Line Tools"
    if [ -f "$VENDORED_DIR/${DYLIBS[0]}" ] && [ -f "$VENDORED_DIR/${DYLIBS[1]}" ]; then
        echo "plugins: vendored in $VENDORED_DIR"
        exit 0
    fi
    if [ -d "$XCODE_PLUGINS" ]; then
        echo "plugins: live Xcode at $XCODE_PLUGINS"
        exit 0
    fi
    echo "plugins: MISSING — run scripts/swift-clt-plugins.sh refresh (needs Xcode)" >&2
    exit 1
}

case "${1:-flags}" in
    flags)   cmd_flags ;;
    refresh) cmd_refresh ;;
    check)   cmd_check ;;
    *) echo "usage: $0 [flags|refresh|check]" >&2; exit 2 ;;
esac