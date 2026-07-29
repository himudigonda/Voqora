#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/validate_release.sh <version> [dmg-path]}"
DMG_PATH="${2:-}"
APP_NAME="Voqora"
INFO_PLIST="frontend/Voqora/Voqora/Info.plist"
PROJECT="frontend/Voqora/Voqora.xcodeproj"

fail() { echo "❌ $1" >&2; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true; }

PUBLIC_KEY="$(value SUPublicEDKey)"
FEED_URL="$(value SUFeedURL)"
[ -n "$PUBLIC_KEY" ] || fail "SUPublicEDKey is missing. Sparkle updates must be signed."
if [ "$PUBLIC_KEY" = '$(SPARKLE_PUBLIC_ED_KEY)' ]; then
    PUBLIC_KEY="$(xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -showBuildSettings 2>/dev/null | awk -F ' = ' '/^[[:space:]]*SPARKLE_PUBLIC_ED_KEY = / { print $2; exit }')"
fi
[ -n "$PUBLIC_KEY" ] || fail "SPARKLE_PUBLIC_ED_KEY is not resolved in the project."
[ -n "$FEED_URL" ] || fail "SUFeedURL is missing."
[[ "$FEED_URL" == https://* ]] || fail "SUFeedURL must use HTTPS."

MARKETING_VERSION="$(xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -showBuildSettings 2>/dev/null | awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }')"
[ "$MARKETING_VERSION" = "$VERSION" ] || fail "Xcode MARKETING_VERSION is $MARKETING_VERSION, expected $VERSION."

if [ -n "$DMG_PATH" ]; then
    [ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH"
    hdiutil imageinfo "$DMG_PATH" >/dev/null || fail "DMG is not a readable disk image."
fi

if [ "${REQUIRE_DISTRIBUTION_SIGNING:-0}" = "1" ]; then
    [ -n "${DEVELOPER_ID_APPLICATION:-}" ] || fail "Set DEVELOPER_ID_APPLICATION for a public distribution build."
    [ -n "${NOTARYTOOL_PROFILE:-}" ] || fail "Set NOTARYTOOL_PROFILE for a public distribution build."
fi

echo "✅ Release preflight passed for ${APP_NAME} ${VERSION}."
