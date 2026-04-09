#!/usr/bin/env bash
# bundle_app.sh — Builds, assembles, and ad-hoc signs BusinessBar.app
#
# Usage:
#   ./scripts/bundle_app.sh [VERSION] [BUILD]
#
# Arguments:
#   VERSION  Human-readable version string written into Info.plist (default: dev)
#   BUILD    Build number written into CFBundleVersion         (default: 0)
#
# Output:
#   BusinessBar.app/   — ready-to-run .app bundle in the project root
#
# Examples:
#   ./scripts/bundle_app.sh              # quick local build
#   ./scripts/bundle_app.sh 1.2.0 42    # versioned build
#
# Design note:
#   Credentials and Sparkle config are injected into the BUILT artifacts
#   (the SPM resource bundle and the assembled .app), never into source
#   files.  This keeps the working tree clean — no git-dirty state after
#   a local build.

set -euo pipefail

VERSION="${1:-dev}"
BUILD="${2:-0}"
APP="BusinessBar.app"
ARCH="arm64-apple-macosx"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$PROJECT_DIR/BusinessBar/Resources"
ENTITLEMENTS="$RESOURCES_DIR/BusinessBar.entitlements"

# Path to the SPM-built resource bundle that contains credentials.json
BUILT_BUNDLE="$PROJECT_DIR/.build/${ARCH}/release/BusinessBar_BusinessBar.bundle"

# ── Step 0 — Read credentials (from .local.json / .env) ─────────────────────
# Credentials are gathered early so they are available for post-build
# injection, but source files are NOT modified at this stage.

CREDS_LOCAL="$RESOURCES_DIR/credentials.local.json"
ENV_FILE="$PROJECT_DIR/.env"

GOOGLE_CLIENT_NUMBER=""
GOOGLE_CLIENT_SECRET=""
SPARKLE_APPCAST_URL=""
SPARKLE_PUBLIC_ED_KEY=""

# Try to read from credentials.local.json first
if [ -f "$CREDS_LOCAL" ]; then
    echo "  ▶ Found credentials.local.json — will use it for release build"
    GOOGLE_CLIENT_NUMBER=$(python3 -c "import json; print(json.load(open('$CREDS_LOCAL'))['google_client_number'])" 2>/dev/null || echo "")
    GOOGLE_CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$CREDS_LOCAL'))['google_client_secret'])" 2>/dev/null || echo "")
    SPARKLE_APPCAST_URL=$(python3 -c "import json; print(json.load(open('$CREDS_LOCAL'))['sparkle_appcast_url'])" 2>/dev/null || echo "")
    SPARKLE_PUBLIC_ED_KEY=$(python3 -c "import json; print(json.load(open('$CREDS_LOCAL'))['sparkle_public_ed_key'])" 2>/dev/null || echo "")
fi

# Fall back to .env if no .local.json or it didn't parse
if [ -z "$GOOGLE_CLIENT_NUMBER" ] && [ -f "$ENV_FILE" ]; then
    echo "  ▶ Falling back to .env for credentials"
    while IFS='=' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue
        case "$key" in
            GOOGLE_CLIENT_NUMBER)  GOOGLE_CLIENT_NUMBER="$value" ;;
            GOOGLE_CLIENT_SECRET)  GOOGLE_CLIENT_SECRET="$value" ;;
            SPARKLE_APPCAST_URL)   SPARKLE_APPCAST_URL="$value" ;;
            SPARKLE_PUBLIC_ED_KEY) SPARKLE_PUBLIC_ED_KEY="$value" ;;
        esac
    done < "$ENV_FILE"
fi

# Strip surrounding quotes if present
GOOGLE_CLIENT_NUMBER="${GOOGLE_CLIENT_NUMBER%\"}"; GOOGLE_CLIENT_NUMBER="${GOOGLE_CLIENT_NUMBER#\"}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET%\"}"; GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET#\"}"
SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL%\"}";   SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL#\"}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY%\"}"; SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY#\"}"

HAS_CREDENTIALS=false
if [ -n "$GOOGLE_CLIENT_NUMBER" ] && [ -n "$GOOGLE_CLIENT_SECRET" ]; then
    HAS_CREDENTIALS=true
else
    echo "  ⚠ No credentials found — credentials.json will use placeholder values."
    echo "    Create BusinessBar/Resources/credentials.local.json with real values."
fi

# ── Step 1 — Build ──────────────────────────────────────────────────────────
echo "==> Building release binary..."
swift build -c release

# ── Step 2 — Inject credentials into BUILT artifacts ────────────────────────
# Patch the credentials.json inside the SPM-built resource bundle, NOT the
# source file.  This keeps the source tree clean.

BUILT_CREDS="$BUILT_BUNDLE/credentials.json"
if [ "$HAS_CREDENTIALS" = true ]; then
    if [ -f "$BUILT_CREDS" ]; then
        cat > "$BUILT_CREDS" <<JSON_EOF
{
    "google_client_number": "${GOOGLE_CLIENT_NUMBER}",
    "google_client_secret": "${GOOGLE_CLIENT_SECRET}"
}
JSON_EOF
        echo "  ✓ Built credentials.json patched with real values"
    else
        echo "  ⚠ Built credentials.json not found at $BUILT_CREDS — skipping"
    fi

    # Also remove credentials.local.json from the built bundle so it never
    # ships in the .app (real values are now in credentials.json).
    BUILT_LOCAL_CREDS="$BUILT_BUNDLE/credentials.local.json"
    if [ -f "$BUILT_LOCAL_CREDS" ]; then
        rm "$BUILT_LOCAL_CREDS"
        echo "  ✓ Removed credentials.local.json from built bundle"
    fi
fi

# ── Step 3 — Assemble .app skeleton ────────────────────────────────────────
echo "==> Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Frameworks"

# ── Step 4 — Copy binary ────────────────────────────────────────────────────
cp ".build/release/BusinessBar" "$APP/Contents/MacOS/"

# ── Step 5 — Copy SPM resource bundles ──────────────────────────────────────
# Swift Package Manager places *.bundle directories alongside the binary.
# Each bundle holds the resources (strings, plists, assets) for its module.
for bundle in ".build/${ARCH}/release"/*.bundle; do
    [ -d "$bundle" ] || continue
    bundle_name="$(basename "$bundle")"
    cp -R "$bundle" "$APP/Contents/Resources/$bundle_name"
    echo "  ✓ bundle: $bundle_name"
done

# Also check the generic release dir (some SPM versions place bundles there)
for bundle in ".build/release"/*.bundle; do
    [ -d "$bundle" ] || continue
    bundle_name="$(basename "$bundle")"
    # Skip if already copied
    [ -d "$APP/Contents/Resources/$bundle_name" ] && continue
    cp -R "$bundle" "$APP/Contents/Resources/$bundle_name"
    echo "  ✓ bundle: $bundle_name"
done

# Remove credentials.local.json from any bundle inside the .app — it should
# never ship in a release build (real values are already in credentials.json).
for bundle_dir in "$APP/Contents/Resources"/*.bundle; do
    [ -d "$bundle_dir" ] || continue
    local_creds="$bundle_dir/credentials.local.json"
    if [ -f "$local_creds" ]; then
        rm "$local_creds"
        echo "  ✓ Removed credentials.local.json from bundle (not for distribution)"
    fi
done

# ── Step 6 — Sparkle.framework ──────────────────────────────────────────────
# Sparkle is a pre-built binary framework linked via @rpath. It must be embedded
# in Contents/Frameworks/ and the binary's rpath must include that directory.
if [ -d ".build/${ARCH}/release/Sparkle.framework" ]; then
    cp -R ".build/${ARCH}/release/Sparkle.framework" "$APP/Contents/Frameworks/"
    echo "  ✓ Sparkle.framework copied"
elif [ -d ".build/release/Sparkle.framework" ]; then
    cp -R ".build/release/Sparkle.framework" "$APP/Contents/Frameworks/"
    echo "  ✓ Sparkle.framework copied"
fi

# Copy any other .framework directories SPM placed in the build dir
for fw in ".build/${ARCH}/release"/*.framework; do
    [ -d "$fw" ] || continue
    fw_name="$(basename "$fw")"
    [ "$fw_name" = "Sparkle.framework" ] && continue   # already handled above
    cp -R "$fw" "$APP/Contents/Frameworks/$fw_name"
    echo "  ✓ framework: $fw_name"
done

install_name_tool \
    -add_rpath @executable_path/../Frameworks \
    "$APP/Contents/MacOS/BusinessBar" 2>/dev/null || true

# ── Step 7 — Info.plist (copy to .app, then patch IN THE .APP) ──────────────
# The source Info.plist is copied as-is, then all patching happens on the
# copy inside the .app bundle so the source file is never modified.
cp "$RESOURCES_DIR/Info.plist" "$APP/Contents/"

# Patch version/build number
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${VERSION}" \
    "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion ${BUILD}" \
    "$APP/Contents/Info.plist"

# Patch URL scheme with real client number (only if credentials are available)
if [ "$HAS_CREDENTIALS" = true ]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 com.googleusercontent.apps.${GOOGLE_CLIENT_NUMBER}" \
        "$APP/Contents/Info.plist" 2>/dev/null || true
    echo "  ✓ Info.plist URL scheme patched"
fi

# Patch Sparkle appcast URL (if available)
if [ -n "$SPARKLE_APPCAST_URL" ]; then
    /usr/libexec/PlistBuddy \
        -c "Set :SUFeedURL ${SPARKLE_APPCAST_URL}" \
        "$APP/Contents/Info.plist" 2>/dev/null || true
    echo "  ✓ Info.plist SUFeedURL patched"
fi

# Patch Sparkle public EdDSA key (if available)
if [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
    /usr/libexec/PlistBuddy \
        -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_ED_KEY}" \
        "$APP/Contents/Info.plist" 2>/dev/null || true
    echo "  ✓ Info.plist SUPublicEDKey patched"
fi

echo "  ✓ Info.plist copied (version ${VERSION}, build ${BUILD})"

# ── Step 8 — App icon & Assets ──────────────────────────────────────────────
# macOS needs either a compiled Assets.car (from actool) or an AppIcon.icns
# file in Contents/Resources for the app icon to appear in Finder, Launchpad,
# and the About window.  We try multiple strategies so the icon always works.

ASSETS_SRC="$RESOURCES_DIR/Assets.xcassets"
ICON_SET_SRC="$ASSETS_SRC/AppIcon.appiconset"
PREGEN_ICNS="$RESOURCES_DIR/AppIcon.icns"
RESOURCES_DEST="$APP/Contents/Resources"
ICON_GENERATED=false

# Strategy 1: Compile Assets.xcassets with actool → produces Assets.car
if [ -d "$ASSETS_SRC" ] && command -v actool &>/dev/null; then
    echo "  ▶ Compiling Assets.xcassets with actool…"
    if actool \
        --output-format human-readable-text \
        --notices --warnings --errors \
        --app-icon AppIcon \
        --enable-on-demand-resources NO \
        --development-region en \
        --minimum-deployment-target 14.0 \
        --platform macosx \
        --output-partial-info-plist /tmp/actool.plist \
        --compile "$RESOURCES_DEST" \
        "$ASSETS_SRC" 2>&1 | grep -E "warning:|error:|compiled" || true; then
        # Verify the .car file was actually produced
        if [ -f "$RESOURCES_DEST/Assets.car" ]; then
            echo "  ✓ Assets.car compiled — app icon available via asset catalog"
            ICON_GENERATED=true
        fi
    else
        echo "  ⚠ actool failed — falling back to iconutil"
    fi
fi

# Strategy 2: Generate AppIcon.icns from the PNGs in AppIcon.appiconset using iconutil
if [ "$ICON_GENERATED" = false ] && [ -d "$ICON_SET_SRC" ] && command -v iconutil &>/dev/null; then
    echo "  ▶ Generating AppIcon.icns with iconutil…"
    ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_TMP"

    # iconutil expects files named icon_16x16.png, icon_16x16@2x.png, etc.
    # The AppIcon.appiconset already uses these exact names.
    for f in "$ICON_SET_SRC"/icon_*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$ICONSET_TMP/"
    done

    # Verify we have at least the 256x256 icon (minimum for a valid .icns)
    if [ -f "$ICONSET_TMP/icon_256x256.png" ] || [ -f "$ICONSET_TMP/icon_128x128@2x.png" ]; then
        if iconutil -c icns "$ICONSET_TMP" -o "$RESOURCES_DEST/AppIcon.icns" 2>/dev/null; then
            echo "  ✓ AppIcon.icns generated — app icon available via .icns file"
            ICON_GENERATED=true
        else
            echo "  ⚠ iconutil failed — falling back to pre-generated .icns"
        fi
    else
        echo "  ⚠ Insufficient icon PNGs for iconutil — falling back to pre-generated .icns"
    fi

    rm -rf "$ICONSET_TMP"
fi

# Strategy 3: Copy the pre-generated AppIcon.icns from Resources/
if [ "$ICON_GENERATED" = false ] && [ -f "$PREGEN_ICNS" ]; then
    cp "$PREGEN_ICNS" "$RESOURCES_DEST/AppIcon.icns"
    echo "  ✓ AppIcon.icns copied from pre-generated file — app icon available"
    ICON_GENERATED=true
fi

# Warning if no icon could be provided
if [ "$ICON_GENERATED" = false ]; then
    echo "  ⚠ No app icon could be generated. The app will use a generic macOS icon."
    echo "    To fix: install Xcode CLI tools (xcode-select --install) or place an"
    echo "    AppIcon.icns file in $RESOURCES_DIR/"
fi

# Copy localisation strings
for lproj in "$RESOURCES_DIR"/*.lproj; do
    [ -d "$lproj" ] || continue
    lproj_name="$(basename "$lproj")"
    cp -R "$lproj" "$RESOURCES_DEST/$lproj_name"
    echo "  ✓ localisation: $lproj_name"
done

# ── Step 9 — Ad-hoc sign (inside-out) ───────────────────────────────────────
# Signing rules:
#  1. Sign nested bundles before their parent (inside-out order).
#  2. codesign --deep is unreliable on versioned framework symlinks (Sparkle),
#     so we sign each component explicitly.
#  3. The main app is signed with entitlements that include
#     com.apple.security.cs.disable-library-validation — required because
#     codesign automatically enables the hardened runtime on app bundles, and
#     hardened runtime + library validation would reject ad-hoc frameworks.

echo "==> Ad-hoc signing (inside-out)..."

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    SPARKLE_B="$SPARKLE/Versions/B"

    # 1. Sparkle's XPC services
    if [ -d "$SPARKLE_B/XPCServices" ]; then
        codesign --force --sign - "$SPARKLE_B/XPCServices/Downloader.xpc" 2>/dev/null || true
        codesign --force --sign - "$SPARKLE_B/XPCServices/Installer.xpc" 2>/dev/null || true
    fi

    # 2. Sparkle's helper app
    if [ -d "$SPARKLE_B/Updater.app" ]; then
        codesign --force --deep --sign - "$SPARKLE_B/Updater.app" 2>/dev/null || true
    fi

    # 3. Sparkle's autoupdate helper
    if [ -f "$SPARKLE_B/Autoupdate" ]; then
        codesign --force --sign - --entitlements "$ENTITLEMENTS" "$SPARKLE_B/Autoupdate" 2>/dev/null || true
    fi

    # 4. Sparkle framework binary + bundle
    codesign --force --sign - "$SPARKLE" 2>/dev/null || true
    echo "  ✓ Sparkle.framework signed"
fi

# Sign remaining frameworks
for fw in "$APP/Contents/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    [[ "$fw" == *Sparkle* ]] && continue
    codesign --force --sign - "$fw" 2>/dev/null || true
done

# 5. Main app (with entitlements so library validation is disabled)
codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

echo "  ✓ ad-hoc signature applied"

# ── Step 10 — Verify ─────────────────────────────────────────────────────────
codesign --verify --deep --strict "$APP" 2>/dev/null && echo "  ✓ signature verified" || true

echo ""
echo "==> Done: ${APP} (version ${VERSION}, build ${BUILD})"
echo "    Run:  open ${APP}"
echo ""