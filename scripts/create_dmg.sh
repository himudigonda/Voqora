#!/bin/bash
set -euo pipefail

# ============================================================
# Voqora DMG Installer Builder
# Produces a drag-and-drop .dmg with:
#   • Custom Voqora dark background with visible install instructions
#   • App icon (left) + Applications alias (right)
#   • Volume icon (Voqora.icns)
#   • A reliable drag-and-drop volume containing only the app and Applications link
# ============================================================

APP_NAME="Voqora"
VERSION="${1:?Usage: ./scripts/create_dmg.sh <version>}"
DMG_NAME="${APP_NAME}-${VERSION}"
BUILD_DIR="build"
XCODE_PROJECT_DIR="frontend/Voqora"
STAGING_DIR="${BUILD_DIR}/dmg-staging"
SCRIPTS_DIR="scripts"
# Packaging is intentionally resource-bounded too. The caller may increase
# this only when the machine is reserved for a deliberate release archive.
XCODE_JOBS="${XCODE_JOBS:-4}"

# ── 0. Locate Xcode ─────────────────────────────────────────
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
    echo "⚠️  Xcode.app not found; using system default (may fail)."
fi
echo "🔧 Developer dir: ${DEVELOPER_DIR:-system default}"

# ── 1. Dependency check ─────────────────────────────────────
if ! command -v create-dmg &>/dev/null; then
    echo "❌ create-dmg is required. Install it with: brew install create-dmg" >&2
    exit 1
fi

# ── 2. Compose the designed background + readable install affordance ───────
BG="${SCRIPTS_DIR}/dmg_background_voqora.png"
PYTHON_EXEC="backend/.venv/bin/python"
if [ ! -f "$PYTHON_EXEC" ]; then
    PYTHON_EXEC="$(which python3)"
fi
if [ ! -f "${SCRIPTS_DIR}/dmg_background_voqora_v2.png" ]; then
    echo "❌ DMG source artwork missing at ${SCRIPTS_DIR}/dmg_background_voqora_v2.png" >&2
    exit 1
fi
"$PYTHON_EXEC" "${SCRIPTS_DIR}/compose_dmg_background.py"
echo "🎨 Using composed Voqora DMG background: $BG"

# ── 3. Generate .icns (always regenerate so it tracks xcassets) ─────────────
ICNS="${SCRIPTS_DIR}/Voqora.icns"
echo "🎨 Generating volume icon..."
{
    ICON_SRC="frontend/Voqora/Voqora/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
    PYTHON_EXEC="backend/.venv/bin/python"
    if [ ! -f "$PYTHON_EXEC" ]; then
        PYTHON_EXEC="$(which python3)"
    fi
    ICONSET_DIR="/tmp/Voqora_build.iconset"
    "$PYTHON_EXEC" -c "
from PIL import Image
import os
img = Image.open('$ICON_SRC').convert('RGBA')
os.makedirs('$ICONSET_DIR', exist_ok=True)
for sz, name in [(16,'16x16'),(32,'16x16@2x'),(32,'32x32'),(64,'32x32@2x'),
                 (128,'128x128'),(256,'128x128@2x'),(256,'256x256'),(512,'256x256@2x'),
                 (512,'512x512'),(1024,'512x512@2x')]:
    img.resize((sz,sz)).save(f'$ICONSET_DIR/icon_{name}.png')
"
    iconutil -c icns "$ICONSET_DIR" -o "$ICNS"
    rm -rf "$ICONSET_DIR"
}
echo "   ✓ Volume icon: $ICNS"

# ── 4. Build Xcode archive ───────────────────────────────────
echo "🏗  Archiving Voqora v${VERSION}..."
# `xcodebuild archive` can reuse an old app bundle at the same archivePath,
# which leaves a stale AppIcon.icns beside the freshly compiled asset catalog.
# Start this disposable release archive clean on every build.
rm -rf "${BUILD_DIR}/${APP_NAME}.xcarchive"
ARCHIVE_LOG="${BUILD_DIR}/archive-${VERSION}.log"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
if ! xcodebuild \
    -project "${XCODE_PROJECT_DIR}/Voqora.xcodeproj" \
    -scheme "Voqora" \
    -configuration Release \
    -jobs "$XCODE_JOBS" \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
    MARKETING_VERSION="${VERSION}" \
    archive \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    >"${ARCHIVE_LOG}" 2>&1; then
    grep -E "^(error:|warning: |Build |MARKETING)" "${ARCHIVE_LOG}" || true
    exit 1
fi
grep -E "^(error:|warning: |Build |MARKETING)" "${ARCHIVE_LOG}" | sed -n '1,30p' || true

APP_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at $APP_PATH" >&2
    exit 1
fi
echo "   ✓ Archived: $APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
echo "   ✓ Archived app code signature is structurally valid."

# ── 5. Stage: app + fonts + backend zip ─────────────────────
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"

FONTS_SRC="frontend/Voqora/Voqora/Resources/Fonts"
FONTS_DST="$STAGING_DIR/${APP_NAME}.app/Contents/Resources/Fonts"
mkdir -p "$FONTS_DST"
if ! ls "$FONTS_SRC"/*.ttf >/dev/null 2>&1; then
    echo "❌ No .ttf fonts found in $FONTS_SRC" >&2; exit 1
fi
cp "$FONTS_SRC"/*.ttf "$FONTS_DST/"
FONT_COUNT=$(ls -1 "$FONTS_DST"/*.ttf 2>/dev/null | wc -l | tr -d ' ')
echo "   ✓ Bundled $FONT_COUNT font(s)."

ZIP_SRC="frontend/Voqora/Voqora/Resources/VoqoraServer.zip"
MANIFEST_SRC="frontend/Voqora/Voqora/Resources/VoqoraServer.manifest.json"
if [ ! -f "$ZIP_SRC" ]; then
    echo "❌ Backend zip missing at $ZIP_SRC — run 'make backend' first." >&2; exit 1
fi
if [ ! -f "$MANIFEST_SRC" ]; then
    echo "❌ Backend manifest missing at $MANIFEST_SRC — run 'make backend' first." >&2; exit 1
fi
cp "$ZIP_SRC" "$STAGING_DIR/${APP_NAME}.app/Contents/Resources/"
cp "$MANIFEST_SRC" "$STAGING_DIR/${APP_NAME}.app/Contents/Resources/"
echo "   ✓ Backend zip bundled ($(du -sh "$ZIP_SRC" | cut -f1))."

for NOTICE in LICENSE COMMERCIAL-LICENSE.md THIRD_PARTY_NOTICES.md; do
    cp "$NOTICE" "$STAGING_DIR/${APP_NAME}.app/Contents/Resources/$NOTICE"
done
echo "   ✓ License and third-party notices bundled."

# Fonts and notices are added after Xcode archives the application, so the
# top-level signature must be refreshed after every staged resource is in its
# final location. Re-signing only the app bundle preserves the nested
# framework signatures that Xcode produced while sealing the changed resources.
STAGED_APP="$STAGING_DIR/${APP_NAME}.app"
codesign --force --sign "$SIGNING_IDENTITY" \
    --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
    "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
echo "   ✓ Final staged app signature seals bundled resources."

# ── 6. Build drag-and-drop DMG ──────────────────────────────
echo "💿 Building installer DMG..."
rm -f "${BUILD_DIR}/${DMG_NAME}.dmg"

# Finder's layout AppleScript can hang indefinitely in a headless CI runner
# with no interactive GUI session, so it must never be an unattended release
# dependency there — but on an interactive Mac (a real local build, like a
# release owner running `make release` at their own desk) it works fine and
# is the only way `--background`/`--icon` positioning actually lands in the
# DMG's .DS_Store instead of silently being ignored.
DMG_EXTRA_ARGS=()
if [ -n "${CI:-}" ]; then
    DMG_EXTRA_ARGS+=(--skip-jenkins)
fi

create-dmg \
    --volname "${APP_NAME} ${VERSION}" \
    --volicon "${ICNS}" \
    --background "${BG}" \
    --window-pos  200 120 \
    --window-size 660 415 \
    --icon-size   128 \
    --icon        "${APP_NAME}.app"  165 205 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link  495 205 \
    --no-internet-enable \
    "${DMG_EXTRA_ARGS[@]+"${DMG_EXTRA_ARGS[@]}"}" \
    "${BUILD_DIR}/${DMG_NAME}.dmg" \
    "$STAGING_DIR"

# ── 7. Cleanup ───────────────────────────────────────────────
rm -rf "$STAGING_DIR"

DMG_PATH="${BUILD_DIR}/${DMG_NAME}.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)

if [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
    echo "🍎 Submitting DMG for Apple notarization..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    echo "   ✓ Notarization ticket stapled."
fi

# The DMG changes when a notarization ticket is stapled, so write the release
# receipt only after every byte of the artifact is final. The manual
# early-access channel uploads this alongside the DMG; the guided installer
# independently checks GitHub's API digest before opening a download.
shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"
echo "   ✓ SHA-256 receipt: $CHECKSUM_PATH"

echo ""
echo "✅ DMG Created: $DMG_PATH  (${DMG_SIZE})"
