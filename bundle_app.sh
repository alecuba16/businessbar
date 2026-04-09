#!/bin/bash
# bundle_app.sh — assembles BusinessBar.app from a completed `swift build` output
#
# Usage:
#   ./bundle_app.sh              → debug build  → BusinessBar.app
#   ./bundle_app.sh release      → release build → BusinessBar.app
#   ./bundle_app.sh release dmg  → release + BusinessBar.dmg
#
# The resulting BusinessBar.app can be:
#   • Double-clicked to run
#   • Dragged to /Applications
#   • Archived / notarised for distribution

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
APP_NAME="BusinessBar"
BUNDLE_ID="com.businessbar.app"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$PROJECT_DIR/BusinessBar/Resources"
ENTITLEMENTS="$RESOURCES_DIR/BusinessBar.entitlements"

# Build mode
BUILD_CONFIG="debug"
if [[ "${1:-}" == "release" ]]; then
    BUILD_CONFIG="release"
fi

BUILD_DIR="$PROJECT_DIR/.build/$BUILD_CONFIG"
OUT_APP="$PROJECT_DIR/$APP_NAME.app"

# ── Step 1a — Inject credentials ──────────────────────────────────────────────
# For release builds, real credentials must be baked into credentials.json
# so they are compiled into the binary (no .local.json in the .app bundle).
#
# Source order: credentials.local.json → .env → leave as placeholder

CREDS_FILE="$RESOURCES_DIR/credentials.json"
CREDS_LOCAL="$RESOURCES_DIR/credentials.local.json"
ENV_FILE="$PROJECT_DIR/.env"

SPARKLE_APPCAST_URL=""
SPARKLE_PUBLIC_ED_KEY=""

# Try to read from credentials.local.json first
if [ -f "$CREDS_LOCAL" ]; then
    echo "  ▶ Found credentials.local.json — using it for release build"
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
            GOOGLE_CLIENT_NUMBER) GOOGLE_CLIENT_NUMBER="$value" ;;
            GOOGLE_CLIENT_SECRET) GOOGLE_CLIENT_SECRET="$value" ;;
            SPARKLE_APPCAST_URL)  SPARKLE_APPCAST_URL="$value" ;;
            SPARKLE_PUBLIC_ED_KEY) SPARKLE_PUBLIC_ED_KEY="$value" ;;
        esac
    done < "$ENV_FILE"
fi

if [ -n "$GOOGLE_CLIENT_NUMBER" ] && [ -n "$GOOGLE_CLIENT_SECRET" ]; then
    # Strip surrounding quotes if present
    GOOGLE_CLIENT_NUMBER="${GOOGLE_CLIENT_NUMBER%\"}"
    GOOGLE_CLIENT_NUMBER="${GOOGLE_CLIENT_NUMBER#\"}"
    GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET%\"}"
    GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET#\"}"

    # Write real values into credentials.json (bakes them into the binary)
    cat > "$CREDS_FILE" <<JSON_EOF
{
    "google_client_number": "${GOOGLE_CLIENT_NUMBER}",
    "google_client_secret": "${GOOGLE_CLIENT_SECRET}"
}
JSON_EOF
    echo "  ✓ credentials.json updated with real values"

    # Patch Info.plist URL scheme
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 com.googleusercontent.apps.${GOOGLE_CLIENT_NUMBER}" \
        "$RESOURCES_DIR/Info.plist" 2>/dev/null || true
    echo "  ✓ Info.plist URL scheme patched"
else
    echo "  ⚠ No credentials found — credentials.json will use placeholder values."
    echo "    Create BusinessBar/Resources/credentials.local.json with real values."
fi

# ── Step 1b — Inject Sparkle config ──────────────────────────────────────────
# The appcast URL and EdDSA public key are not secrets — they are public values
# embedded in the app binary for Sparkle's update verification. Source order:
# credentials.local.json → .env → leave as placeholder.

if [ -n "$SPARKLE_APPCAST_URL" ]; then
    # Strip surrounding quotes if present
    SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL%\"}"
    SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL#\"}"
    /usr/libexec/PlistBuddy \
        -c "Set :SUFeedURL ${SPARKLE_APPCAST_URL}" \
        "$RESOURCES_DIR/Info.plist" 2>/dev/null || true
    echo "  ✓ Info.plist SUFeedURL patched"
fi

if [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
    # Strip surrounding quotes if present
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY%\"}"
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY#\"}"
    /usr/libexec/PlistBuddy \
        -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_ED_KEY}" \
        "$RESOURCES_DIR/Info.plist" 2>/dev/null || true
    echo "  ✓ Info.plist SUPublicEDKey patched"
fi

# ── Step 1 — Build ─────────────────────────────────────────────────────────────
echo "▶ Building ($BUILD_CONFIG)…"
if [[ "$BUILD_CONFIG" == "release" ]]; then
    swift build -c release
else
    swift build
fi
echo "  ✓ swift build complete"

# ── Step 2 — Create .app skeleton ──────────────────────────────────────────────
echo "▶ Assembling $APP_NAME.app…"
rm -rf "$OUT_APP"
MACOS_DIR="$OUT_APP/Contents/MacOS"
FRAMEWORKS_DIR="$OUT_APP/Contents/Frameworks"
RESOURCES_DEST="$OUT_APP/Contents/Resources"

mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DEST"

# ── Step 3 — Copy executable ───────────────────────────────────────────────────
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
echo "  ✓ executable copied"

# ── Step 4 — Copy Info.plist ───────────────────────────────────────────────────
cp "$RESOURCES_DIR/Info.plist" "$OUT_APP/Contents/Info.plist"
echo "  ✓ Info.plist copied"

# ── Step 5 — Copy SPM resource bundles ────────────────────────────────────────
# Swift Package Manager places *.bundle directories alongside the binary.
# Each bundle holds the resources (strings, plists, assets) for its module.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    bundle_name="$(basename "$bundle")"
    cp -R "$bundle" "$RESOURCES_DEST/$bundle_name"
    echo "  ✓ bundle: $bundle_name"
done

# Remove credentials.local.json from the .app bundle — it should never
# ship in a release build (real values are already in credentials.json).
if [ -f "$RESOURCES_DEST/BusinessBar_BusinessBar.bundle/credentials.local.json" ]; then
    rm "$RESOURCES_DEST/BusinessBar_BusinessBar.bundle/credentials.local.json"
    echo "  ✓ Removed credentials.local.json from bundle (not for distribution)"
fi

# ── Step 6 — Copy Sparkle.framework ───────────────────────────────────────────
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    cp -R "$BUILD_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/Sparkle.framework"
    echo "  ✓ Sparkle.framework copied"
fi

# Copy any other .framework directories SPM placed in the build dir
for fw in "$BUILD_DIR"/*.framework; do
    [ -d "$fw" ] || continue
    fw_name="$(basename "$fw")"
    [ "$fw_name" = "Sparkle.framework" ] && continue   # already handled above
    cp -R "$fw" "$FRAMEWORKS_DIR/$fw_name"
    echo "  ✓ framework: $fw_name"
done

# ── Step 7 — Fix up Sparkle's embedded helpers (rpath) ────────────────────────
# Sparkle bundles Autoupdate.app and XPC services; they need correct rpaths.
SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    # Update rpath in main binary so it finds Sparkle in @executable_path/../Frameworks
    install_name_tool \
        -add_rpath "@executable_path/../Frameworks" \
        "$MACOS_DIR/$APP_NAME" 2>/dev/null || true
    echo "  ✓ rpath updated for Sparkle"
fi

# ── Step 8 — App icon & Assets ─────────────────────────────────────────────────
# macOS needs either a compiled Assets.car (from actool) or an AppIcon.icns
# file in Contents/Resources for the app icon to appear in Finder, Launchpad,
# and the About window.  We try multiple strategies so the icon always works.

ASSETS_SRC="$RESOURCES_DIR/Assets.xcassets"
ICON_SET_SRC="$ASSETS_SRC/AppIcon.appiconset"
PREGEN_ICNS="$RESOURCES_DIR/AppIcon.icns"
ICON_GENERATED=false

# Strategy 1: Compile Assets.xcassets with actool → produces Assets.car
if [ -d "$ASSETS_SRC" ] && command -v actool &>/dev/null; then
    echo "  ▶ Compiling Assets.xcassets with actool…"
    if actool \
        --output-format human-readable-text \
        --notices --warnings \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /dev/null \
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

# ── Step 9 — Code-sign ────────────────────────────────────────────────────────
# Ad-hoc sign (no Developer ID required) so macOS will run the app locally.
# For distribution replace "-" with "Developer ID Application: Your Name (TEAMID)"
echo "▶ Code-signing (ad-hoc)…"

# Sign frameworks first (inside-out)
if [ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]; then
    # Sign the XPC services and helpers inside Sparkle
    for helper in \
        "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
        "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
        "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Autoupdate" \
        "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app"; do
        [ -e "$helper" ] && \
            codesign --force --sign "-" \
                --entitlements "$ENTITLEMENTS" \
                "$helper" 2>/dev/null || true
    done
    codesign --force --sign "-" "$FRAMEWORKS_DIR/Sparkle.framework" 2>/dev/null || true
fi

# Sign remaining frameworks
for fw in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$fw" ] || continue
    [[ "$fw" == *Sparkle* ]] && continue
    codesign --force --sign "-" "$fw" 2>/dev/null || true
done

# Sign the app bundle (preserves metadata)
codesign \
    --force \
    --sign "-" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$OUT_APP"

echo "  ✓ ad-hoc signature applied"

# ── Step 10 — Verify ──────────────────────────────────────────────────────────
codesign --verify --deep --strict "$OUT_APP" && echo "  ✓ signature verified"
echo ""
echo "✅  $OUT_APP is ready."
echo "    Double-click it or drag it to /Applications to run."
echo ""

# ── Step 11 — Optional DMG ────────────────────────────────────────────────────
if [[ "${2:-}" == "dmg" ]]; then
    DMG_PATH="$PROJECT_DIR/$APP_NAME.dmg"
    echo "▶ Creating $APP_NAME.dmg…"
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$OUT_APP" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
    echo "✅  $DMG_PATH created."
fi