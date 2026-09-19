#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/validate_release.sh <version> [dmg-path]}"
DMG_PATH="${2:-}"
APP_NAME="Voqora"
INFO_PLIST="frontend/Voqora/Voqora/Info.plist"
PROJECT="frontend/Voqora/Voqora.xcodeproj"
BACKEND_PROJECT="backend/pyproject.toml"
BACKEND_CONFIG="backend/app/core/config.py"
BACKEND_ARCHIVE="frontend/Voqora/Voqora/Resources/VoqoraServer.zip"
BACKEND_MANIFEST="frontend/Voqora/Voqora/Resources/VoqoraServer.manifest.json"
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
(
    cd backend
    uv lock --check
) || fail "backend/uv.lock is stale; regenerate and review it before releasing."
if [ -f "$BACKEND_ARCHIVE" ] || [ -f "$BACKEND_MANIFEST" ]; then
    [ -f "$BACKEND_ARCHIVE" ] || fail "Backend archive is missing. Run make backend."
    [ -f "$BACKEND_MANIFEST" ] || fail "Backend manifest is missing. Run make backend."
    python3 scripts/generate_backend_manifest.py \
        --archive "$BACKEND_ARCHIVE" \
        --version "$VERSION" \
        --verify "$BACKEND_MANIFEST" \
        || fail "Backend manifest does not seal the exact bundled archive."
elif [ "${ALLOW_MISSING_BACKEND_ARTIFACT:-0}" != "1" ]; then
    fail "Backend archive is missing. Run make backend."
fi

if [ "${REQUIRE_DISTRIBUTION_SIGNING:-0}" = "1" ]; then
    [ -n "${DEVELOPER_ID_APPLICATION:-}" ] || fail "Set DEVELOPER_ID_APPLICATION for a public distribution build."
    [ -n "${NOTARYTOOL_PROFILE:-}" ] || fail "Set NOTARYTOOL_PROFILE for a public distribution build."
fi

if [ -n "$DMG_PATH" ]; then
    [ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH"
    CHECKSUM_PATH="${DMG_PATH}.sha256"
    [ -f "$CHECKSUM_PATH" ] || fail "DMG checksum receipt is missing: $CHECKSUM_PATH"
    # `create_dmg.sh` writes the exact path passed to `shasum`; compare it as
    # data rather than interpolating a versioned filename into an awk regex.
    EXPECTED_SHA256="$(awk -v filename="$DMG_PATH" '$2 == filename && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); exit }' "$CHECKSUM_PATH")"
    ACTUAL_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    [ -n "$EXPECTED_SHA256" ] || fail "DMG checksum receipt has no SHA-256 entry for $DMG_PATH."
    [ "$EXPECTED_SHA256" = "$ACTUAL_SHA256" ] || fail "DMG checksum receipt does not match the exact DMG. Rebuild the receipt."
    hdiutil imageinfo "$DMG_PATH" >/dev/null || fail "DMG is not a readable disk image."

    ATTACH_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
    MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '$3 ~ "^/Volumes/" { print $3; exit }')"
    [ -n "$MOUNT_POINT" ] || fail "DMG mounted without a readable volume."
    trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT
    APP_PATH="$MOUNT_POINT/${APP_NAME}.app"
    [ -d "$APP_PATH" ] || fail "DMG does not contain ${APP_NAME}.app."
    [ -L "$MOUNT_POINT/Applications" ] || fail "DMG does not contain an Applications alias."
    BUNDLED_ARCHIVE="$APP_PATH/Contents/Resources/VoqoraServer.zip"
    BUNDLED_MANIFEST="$APP_PATH/Contents/Resources/VoqoraServer.manifest.json"
    [ -f "$BUNDLED_ARCHIVE" ] || fail "Mounted app is missing the backend archive."
    [ -f "$BUNDLED_MANIFEST" ] || fail "Mounted app is missing the backend integrity manifest."
    python3 scripts/generate_backend_manifest.py \
        --archive "$BUNDLED_ARCHIVE" \
        --version "$VERSION" \
        --verify "$BUNDLED_MANIFEST" \
        || fail "Mounted app backend manifest does not match its archive."
    python3 scripts/test_frozen_backend.py --archive "$BUNDLED_ARCHIVE" \
        || fail "Mounted app backend archive failed the authenticated runtime check."
    codesign --verify --deep --strict "$APP_PATH" || fail "Mounted app has an invalid code signature."
    MOUNTED_APP_SIGNING_DETAILS="$(codesign -dvv "$APP_PATH" 2>&1)"
    MOUNTED_APP_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^#* *designated => //p')"
    [ -n "$MOUNTED_APP_REQUIREMENT" ] \
        || fail "Could not read the mounted app's designated requirement."
    hdiutil detach "$MOUNT_POINT" >/dev/null
    trap - EXIT

    # Refuse a cdhash-pinned designated requirement on EVERY path, including
    # the deliberate unnotarized one. macOS keys Accessibility and Automation
    # grants to this requirement and stores one row per bundle identifier, so
    # a requirement naming a code hash rather than a certificate means every
    # user loses those permissions on the next update — while the stale
    # Settings toggle still reads as enabled. That is not a Gatekeeper
    # tradeoff a release owner can knowingly accept for a faster ship; it
    # silently breaks the product's core feature for existing users. v1.2.4
    # shipped this way. An unsigned/unnotarized DMG remains possible, but it
    # must still carry a certificate-backed identity.
    case "$MOUNTED_APP_REQUIREMENT" in
        *cdhash*)
            fail "Mounted app has a cdhash-pinned designated requirement (ad-hoc signature).
       Every user would lose Accessibility permission on the next update.
       Set DEVELOPER_ID_APPLICATION, or LOCAL_SIGN_IDENTITY for a
       non-distributable build. Requirement was:
       $MOUNTED_APP_REQUIREMENT"
            ;;
    esac
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
