#!/bin/bash
set -euo pipefail

# ============================================================
# Voqora DMG Installer Builder
# Produces a drag-and-drop .dmg with:
#   • Custom Voqora dark background with visible install instructions
#   • App icon (left) + Applications alias (right)
#   • Volume icon (Voqora.icns)
#   • 660×415 Finder window, icon size 128px
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
if [ ! -f "$ZIP_SRC" ]; then
    echo "❌ Backend zip missing at $ZIP_SRC — run 'make backend' first." >&2; exit 1
fi
cp "$ZIP_SRC" "$STAGING_DIR/${APP_NAME}.app/Contents/Resources/"
echo "   ✓ Backend zip bundled ($(du -sh "$ZIP_SRC" | cut -f1))."

for NOTICE in LICENSE COMMERCIAL-LICENSE.md THIRD_PARTY_NOTICES.md; do
    cp "$NOTICE" "$STAGING_DIR/${APP_NAME}.app/Contents/Resources/$NOTICE"
done
echo "   ✓ License and third-party notices bundled."

# The disk image carries its own readable first-run support path. This is a
# deliberate temporary supplement to the non-notarized early-access channel,
# not an unattended installer or a substitute for Apple notarization.
for SUPPORT_FILE in README-FIRST.txt OPTIONAL-OPEN-VOQORA.command; do
    cp "installer/${SUPPORT_FILE}" "$STAGING_DIR/${SUPPORT_FILE}"
done
chmod +x "$STAGING_DIR/OPTIONAL-OPEN-VOQORA.command"
echo "   ✓ Bundled early-access install guidance."

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

create-dmg \
    --volname "${APP_NAME} ${VERSION}" \
    --volicon "${ICNS}" \
    --background "${BG}" \
    --window-pos  200 120 \
    --window-size 660 415 \
    --icon-size   128 \
    --icon        "${APP_NAME}.app"  165 200 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link  495 200 \
    --icon "README-FIRST.txt" 165 350 \
    --icon "OPTIONAL-OPEN-VOQORA.command" 495 350 \
    --no-internet-enable \
    "${BUILD_DIR}/${DMG_NAME}.dmg" \
    "$STAGING_DIR"

# ── 7. Cleanup ───────────────────────────────────────────────
rm -rf "$STAGING_DIR"

DMG_SIZE=$(du -sh "${BUILD_DIR}/${DMG_NAME}.dmg" | cut -f1)

if [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
    echo "🍎 Submitting DMG for Apple notarization..."
    xcrun notarytool submit "${BUILD_DIR}/${DMG_NAME}.dmg" \
        --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "${BUILD_DIR}/${DMG_NAME}.dmg"
    xcrun stapler validate "${BUILD_DIR}/${DMG_NAME}.dmg"
    echo "   ✓ Notarization ticket stapled."
fi

echo ""
echo "✅ DMG Created: ${BUILD_DIR}/${DMG_NAME}.dmg  (${DMG_SIZE})"
