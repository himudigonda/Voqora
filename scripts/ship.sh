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

./scripts/validate_release.sh "$VERSION" "$DMG_PATH"
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
NOTES="$(awk -v heading="## [${VERSION}]" '
    index($0, heading) == 1 { capture = 1; next }
    capture && /^## \[/ { exit }
    capture { print }
' CHANGELOG.md)"
if [ -z "$NOTES" ]; then
    echo "❌ CHANGELOG.md needs a section beginning '## [${VERSION}]'." >&2
    exit 1
fi

git push origin HEAD:main
git tag -a "$TAG" -m "${APP_NAME} ${TAG}"
git push origin "$TAG"

gh release create "$TAG" "$DMG_PATH" \
    --title "${APP_NAME} ${TAG}" \
    --notes "$NOTES"

echo "✅ ${APP_NAME} ${TAG} is live."
