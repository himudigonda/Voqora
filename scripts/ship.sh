#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/ship.sh <version>}"
TAG="v${VERSION}"
APP_NAME="Voqora"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG not found at $DMG_PATH. Run 'make release VERSION=$VERSION' first." >&2
    exit 1
fi

# A public upload should not accidentally turn an ad-hoc local candidate into
# the official download. The normal path requires Developer ID signing and a
# stapled notarization ticket. The free distribution fallback still exists for
# deliberate experiments, but it requires an unmistakable opt-in and the
# resulting support burden is documented rather than hidden.
if [ "${ALLOW_UNNOTARIZED_PUBLIC_RELEASE:-0}" = "1" ]; then
    echo "⚠️  Explicitly allowing an unnotarized public DMG. Gatekeeper friction is expected."
    ./scripts/validate_release.sh "$VERSION" "$DMG_PATH"
else
    REQUIRE_DISTRIBUTION_SIGNING=1 ./scripts/validate_release.sh "$VERSION" "$DMG_PATH"
fi
bash ./scripts/validate_appcast.sh "$VERSION" "$DMG_PATH" docs/updates/appcast.xml

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

if ! rg -F "${APP_NAME}-${VERSION}.dmg" docs/updates/appcast.xml >/dev/null 2>&1; then
    echo "❌ docs/updates/appcast.xml does not contain ${APP_NAME}-${VERSION}.dmg. Run 'make appcast VERSION=${VERSION}', commit it, then retry." >&2
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

git tag -a "$TAG" -m "${APP_NAME} ${TAG}"
git push origin "$TAG"
TAG_PUSHED=1

gh release create "$TAG" "$DMG_PATH" \
    --title "${APP_NAME} ${TAG}" \
    --notes "$NOTES"
RELEASE_CREATED=1

ASSET_URL="https://github.com/himudigonda/Voqora/releases/download/${TAG}/${APP_NAME}-${VERSION}.dmg"
curl --fail --location --head --retry 5 --retry-delay 2 "$ASSET_URL" >/dev/null

# The appcast already names this immutable release asset. Do not publish the
# branch that GitHub Pages serves until the asset exists, otherwise a running
# app can discover a feed enclosure that still returns 404.
git push origin HEAD:main
trap - ERR

echo "✅ ${APP_NAME} ${TAG} is live. Wait for the Pages workflow, then verify the live appcast and an installed older build."
