#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/ship.sh <version>}"
TAG="v${VERSION}"
APP_NAME="Voqora"
BUILD_DIR="${BUILD_DIR:-build}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-notarized}"
DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"
APPCAST_PATH="${APPCAST_PATH:-docs/updates/appcast.xml}"
VALIDATE_RELEASE_SCRIPT="${VALIDATE_RELEASE_SCRIPT:-./scripts/validate_release.sh}"
VALIDATE_APPCAST_SCRIPT="${VALIDATE_APPCAST_SCRIPT:-./scripts/validate_appcast.sh}"

case "$RELEASE_CHANNEL" in
    notarized | manual) ;;
    *)
        echo "❌ RELEASE_CHANNEL must be 'notarized' or 'manual', got '$RELEASE_CHANNEL'." >&2
        exit 2
        ;;
esac

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG not found at $DMG_PATH. Run 'make release VERSION=$VERSION' first." >&2
    exit 1
fi
[ -f "$CHECKSUM_PATH" ] || {
    echo "❌ DMG checksum receipt not found at $CHECKSUM_PATH. Re-run 'make release VERSION=$VERSION'." >&2
    exit 1
}

# A public upload should not accidentally turn an ad-hoc local candidate into
# the official download. The normal path requires Developer ID signing and a
# stapled notarization ticket. The free distribution fallback still exists for
# deliberate experiments, but it requires an unmistakable opt-in and the
# resulting support burden is documented rather than hidden.
if [ "$RELEASE_CHANNEL" = "manual" ]; then
    if [ "${ALLOW_UNNOTARIZED_PUBLIC_RELEASE:-0}" != "1" ]; then
        echo "❌ Manual early-access publishing requires ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1." >&2
        exit 1
    fi
    echo "⚠️  Manual early-access channel selected. Gatekeeper friction is expected; automatic Sparkle replacement remains disabled."
    "$VALIDATE_RELEASE_SCRIPT" "$VERSION" "$DMG_PATH"
    [ -f "$APPCAST_PATH" ] || {
        echo "❌ Existing appcast is missing at $APPCAST_PATH. Preserve the prior signed update feed before publishing a manual release." >&2
        exit 1
    }
    if rg -F "${APP_NAME}-${VERSION}.dmg" "$APPCAST_PATH" >/dev/null 2>&1; then
        echo "❌ $APPCAST_PATH already advertises ${APP_NAME}-${VERSION}.dmg. Manual releases must not enter the Sparkle appcast." >&2
        exit 1
    fi
else
    if [ "${ALLOW_UNNOTARIZED_PUBLIC_RELEASE:-0}" = "1" ]; then
        echo "❌ The notarized channel never accepts ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1. Use RELEASE_CHANNEL=manual for the explicit early-access flow." >&2
        exit 1
    fi
    REQUIRE_DISTRIBUTION_SIGNING=1 "$VALIDATE_RELEASE_SCRIPT" "$VERSION" "$DMG_PATH"
    bash "$VALIDATE_APPCAST_SCRIPT" "$VERSION" "$DMG_PATH" "$APPCAST_PATH"
fi

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "❌ No origin remote is configured." >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Commit or stash all changes before shipping a release." >&2
    exit 1
fi

BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != "main" ]; then
    echo "❌ Releases must ship from main (current branch: ${BRANCH:-detached HEAD})." >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "❌ Tag ${TAG} already exists. Refusing to replace an existing release." >&2
    exit 1
fi

if [ "$RELEASE_CHANNEL" = "notarized" ] && ! rg -F "${APP_NAME}-${VERSION}.dmg" "$APPCAST_PATH" >/dev/null 2>&1; then
    echo "❌ $APPCAST_PATH does not contain ${APP_NAME}-${VERSION}.dmg. Run 'make appcast VERSION=${VERSION}', commit it, then retry." >&2
    exit 1
fi

echo "🚢 Publishing ${APP_NAME} ${TAG}"
TAG_PUSHED=0
RELEASE_CREATED=0
cleanup_failed_pre_release() {
    # A failed upload should not strand a release-looking tag. Once the GitHub
    # release exists, preserve it for diagnosis instead of deleting history.
    if [ "$TAG_PUSHED" = "1" ] && [ "$RELEASE_CREATED" = "0" ]; then
        git push origin ":refs/tags/${TAG}" >/dev/null 2>&1 || true
        git tag -d "$TAG" >/dev/null 2>&1 || true
    fi
}
trap cleanup_failed_pre_release ERR
NOTES="$(awk -v heading="## [${VERSION}]" '
    index($0, heading) == 1 { capture = 1; next }
    capture && /^## \[/ { exit }
    capture { print }
' CHANGELOG.md)"
if [ -z "$NOTES" ]; then
    echo "❌ CHANGELOG.md needs a section beginning '## [${VERSION}]'." >&2
    exit 1
fi
if [ "$RELEASE_CHANNEL" = "manual" ]; then
    NOTES="${NOTES}

### Installation note

This is a checksum-verified manual early-access DMG. It does not use automatic Sparkle replacement; open the verified DMG and drag Voqora to Applications. macOS may require its standard **Open Anyway** confirmation until Developer ID signing and notarization are available."
fi

git tag -a "$TAG" -m "${APP_NAME} ${TAG}"
git push origin "$TAG"
TAG_PUSHED=1

gh release create "$TAG" "$DMG_PATH" "$CHECKSUM_PATH" \
    --title "${APP_NAME} ${TAG}" \
    --notes "$NOTES"
RELEASE_CREATED=1

ASSET_URL="https://github.com/himudigonda/Voqora/releases/download/${TAG}/${APP_NAME}-${VERSION}.dmg"
curl --fail --location --head --retry 5 --retry-delay 2 "$ASSET_URL" >/dev/null
CHECKSUM_URL="${ASSET_URL}.sha256"
curl --fail --location --head --retry 5 --retry-delay 2 "$CHECKSUM_URL" >/dev/null

# For the notarized channel, the appcast already names this immutable asset.
# For the manual channel this push publishes the reviewed source only: the
# matching DMG is deliberately absent from the appcast, so older clients can
# never discover it as an automatic replacement.
git push origin HEAD:main
trap - ERR

if [ "$RELEASE_CHANNEL" = "manual" ]; then
    echo "✅ ${APP_NAME} ${TAG} is live as a manual early-access release. Verify the published DMG and .sha256 receipt from a clean Mac; do not expect an appcast update."
else
    echo "✅ ${APP_NAME} ${TAG} is live. Wait for the Pages workflow, then verify the live appcast and an installed older build."
fi
