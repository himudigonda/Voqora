#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/create_appcast.sh <version>}"
APP_NAME="Voqora"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"
OUTPUT_DIR="docs/updates"
OUTPUT_PATH="${OUTPUT_DIR}/appcast.xml"
SPARKLE_BIN="${SPARKLE_BIN:-$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f -print -quit 2>/dev/null)}"
VERIFY_SCRIPT="scripts/validate_appcast.sh"
# Sparkle appends the archive filename to this prefix. Keep the trailing slash
# so GitHub receives /download/vX.Y.Z/<archive>, not /download/<archive>.
RELEASE_URL="https://github.com/himudigonda/Voqora/releases/download/v${VERSION}/"

fail() { echo "❌ $1" >&2; exit 1; }
[ -f "$DMG_PATH" ] || fail "DMG not found at $DMG_PATH. Run make release VERSION=$VERSION first."
[ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN" ] || fail "Sparkle tools are unavailable. Resolve Xcode packages first."

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voqora-appcast.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
if [ -f "$OUTPUT_PATH" ]; then cp "$OUTPUT_PATH" "$STAGING_DIR/appcast.xml"; fi
cp "$DMG_PATH" "$STAGING_DIR/${APP_NAME}-${VERSION}.dmg"
awk -v heading="## [${VERSION}]" '
    index($0, heading) == 1 { capture = 1; next }
    capture && /^## \[/ { exit }
    capture { print }
' CHANGELOG.md > "$STAGING_DIR/${APP_NAME}-${VERSION}.md"

"$SPARKLE_BIN" --download-url-prefix "$RELEASE_URL" --embed-release-notes \
    --maximum-versions 3 -o "$STAGING_DIR/appcast.xml" "$STAGING_DIR"

mkdir -p "$OUTPUT_DIR"
cp "$STAGING_DIR/appcast.xml" "$OUTPUT_PATH"
bash "$VERIFY_SCRIPT" "$VERSION" "$DMG_PATH" "$OUTPUT_PATH"
echo "✅ Signed appcast written to $OUTPUT_PATH. Commit it before shipping."
