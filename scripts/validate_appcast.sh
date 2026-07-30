#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/validate_appcast.sh <version> <dmg-path> [appcast-path]}"
DMG_PATH="${2:?Usage: ./scripts/validate_appcast.sh <version> <dmg-path> [appcast-path]}"
APPCAST_PATH="${3:-docs/updates/appcast.xml}"
APP_NAME="Voqora"

fail() { echo "❌ $1" >&2; exit 1; }
[ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH"
[ -f "$APPCAST_PATH" ] || fail "Appcast not found: $APPCAST_PATH"

ENCLOSURE="$(rg -F "${APP_NAME}-${VERSION}.dmg" "$APPCAST_PATH" | head -n 1 || true)"
[ -n "$ENCLOSURE" ] || fail "Appcast has no enclosure for ${APP_NAME}-${VERSION}.dmg."

SIGNATURE="$(printf '%s\n' "$ENCLOSURE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
DECLARED_LENGTH="$(printf '%s\n' "$ENCLOSURE" | sed -n 's/.* length="\([0-9][0-9]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] || fail "Appcast enclosure has no Sparkle signature."
[ -n "$DECLARED_LENGTH" ] || fail "Appcast enclosure has no byte length."

ACTUAL_LENGTH="$(stat -f%z "$DMG_PATH")"
[ "$DECLARED_LENGTH" = "$ACTUAL_LENGTH" ] || fail "Appcast length is ${DECLARED_LENGTH}; DMG is ${ACTUAL_LENGTH}. Re-sign this exact file."

SIGN_UPDATE="${SIGN_UPDATE:-$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' -type f -print -quit 2>/dev/null)}"
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || fail "Sparkle signing tools are unavailable."
"$SIGN_UPDATE" --verify "$DMG_PATH" "$SIGNATURE" >/dev/null || fail "Sparkle signature does not match this exact DMG."

echo "✅ Appcast signature and byte length match ${APP_NAME} ${VERSION}."
