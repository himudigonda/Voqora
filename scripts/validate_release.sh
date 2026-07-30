#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/validate_release.sh <version> [dmg-path]}"
DMG_PATH="${2:-}"
APP_NAME="Voqora"
INFO_PLIST="frontend/Voqora/Voqora/Info.plist"
PROJECT="frontend/Voqora/Voqora.xcodeproj"
BACKEND_PROJECT="backend/pyproject.toml"
BACKEND_CONFIG="backend/app/core/config.py"
MOUNTED_APP_SIGNING_DETAILS=""

fail() { echo "❌ $1" >&2; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true; }

# `xcodebuild -showBuildSettings` is not free. Read the project settings once
# and derive every required value from that one receipt.
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -showBuildSettings 2>/dev/null)"
project_setting() {
    local key="$1"
    printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }'
}

PUBLIC_KEY="$(value SUPublicEDKey)"
FEED_URL="$(value SUFeedURL)"
[ -n "$PUBLIC_KEY" ] || fail "SUPublicEDKey is missing. Sparkle updates must be signed."
if [ "$PUBLIC_KEY" = '$(SPARKLE_PUBLIC_ED_KEY)' ]; then
    PUBLIC_KEY="$(project_setting SPARKLE_PUBLIC_ED_KEY)"
fi
[ -n "$PUBLIC_KEY" ] || fail "SPARKLE_PUBLIC_ED_KEY is not resolved in the project."
[ -n "$FEED_URL" ] || fail "SUFeedURL is missing."
[[ "$FEED_URL" == https://* ]] || fail "SUFeedURL must use HTTPS."

MARKETING_VERSION="$(project_setting MARKETING_VERSION)"
[ "$MARKETING_VERSION" = "$VERSION" ] || fail "Xcode MARKETING_VERSION is $MARKETING_VERSION, expected $VERSION."

BUILD_NUMBER="$(project_setting CURRENT_PROJECT_VERSION)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "Xcode CURRENT_PROJECT_VERSION must be a positive integer, got '${BUILD_NUMBER:-missing}'."

BACKEND_PACKAGE_VERSION="$(awk -F '"' '/^version[[:space:]]*=/ { print $2; exit }' "$BACKEND_PROJECT")"
BACKEND_RUNTIME_VERSION="$(awk -F '"' '/^[[:space:]]*VERSION:[[:space:]]*str[[:space:]]*=/ { print $2; exit }' "$BACKEND_CONFIG")"
[ "$BACKEND_PACKAGE_VERSION" = "$VERSION" ] \
    || fail "Backend package version is ${BACKEND_PACKAGE_VERSION:-missing}, expected $VERSION."
[ "$BACKEND_RUNTIME_VERSION" = "$VERSION" ] \
    || fail "Backend runtime version is ${BACKEND_RUNTIME_VERSION:-missing}, expected $VERSION."

if [ "${REQUIRE_DISTRIBUTION_SIGNING:-0}" = "1" ]; then
    [ -n "${DEVELOPER_ID_APPLICATION:-}" ] || fail "Set DEVELOPER_ID_APPLICATION for a public distribution build."
    [ -n "${NOTARYTOOL_PROFILE:-}" ] || fail "Set NOTARYTOOL_PROFILE for a public distribution build."
fi

if [ -n "$DMG_PATH" ]; then
    [ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH"
    hdiutil imageinfo "$DMG_PATH" >/dev/null || fail "DMG is not a readable disk image."

    ATTACH_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
    MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '$3 ~ "^/Volumes/" { print $3; exit }')"
    [ -n "$MOUNT_POINT" ] || fail "DMG mounted without a readable volume."
    trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT
    APP_PATH="$MOUNT_POINT/${APP_NAME}.app"
    [ -d "$APP_PATH" ] || fail "DMG does not contain ${APP_NAME}.app."
    [ -L "$MOUNT_POINT/Applications" ] || fail "DMG does not contain an Applications alias."
    codesign --verify --deep --strict "$APP_PATH" || fail "Mounted app has an invalid code signature."
    MOUNTED_APP_SIGNING_DETAILS="$(codesign -dvv "$APP_PATH" 2>&1)"
    hdiutil detach "$MOUNT_POINT" >/dev/null
    trap - EXIT
fi

if [ "${REQUIRE_DISTRIBUTION_SIGNING:-0}" = "1" ]; then
    if [ -n "$DMG_PATH" ]; then
        TEAM_IDENTIFIER="$(printf '%s\n' "$MOUNTED_APP_SIGNING_DETAILS" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
        [ -n "$TEAM_IDENTIFIER" ] && [ "$TEAM_IDENTIFIER" != "not set" ] \
            || fail "Mounted app is not signed with a Developer ID team."
        xcrun stapler validate "$DMG_PATH" >/dev/null \
            || fail "DMG has no stapled notarization ticket."
        spctl --assess --type open --context context:primary-signature "$DMG_PATH" >/dev/null 2>&1 \
            || fail "Gatekeeper does not accept this DMG."
    fi
fi

echo "✅ Release preflight passed for ${APP_NAME} ${VERSION}."
