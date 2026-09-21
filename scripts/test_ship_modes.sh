#!/bin/bash
set -euo pipefail

# Exercise the release-channel branch logic without creating a tag, release,
# or network request. The production script remains the single implementation;
# this harness replaces only its external command boundaries in a disposable
# directory and asserts the observable safety contract.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voqora-ship-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
BIN_DIR="$TEST_DIR/bin"
BUILD_DIR="$TEST_DIR/build"
LOG_PATH="$TEST_DIR/calls.log"
mkdir -p "$BIN_DIR" "$BUILD_DIR"

DMG_PATH="$BUILD_DIR/Voqora-1.2.3.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"
printf 'release fixture\n' > "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

cat > "$BIN_DIR/git" <<'EOF'
#!/bin/bash
case "${1:-}" in
    remote) exit 0 ;;
    status) exit 0 ;;
    branch) printf 'main\n' ;;
    rev-parse) exit 1 ;;
    tag | push) printf 'git %s\n' "$*" >> "$SHIP_TEST_LOG" ;;
    *) printf 'unexpected git invocation: %s\n' "$*" >&2; exit 99 ;;
esac
EOF

cat > "$BIN_DIR/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$SHIP_TEST_LOG"
EOF

cat > "$BIN_DIR/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$SHIP_TEST_LOG"
EOF

cat > "$TEST_DIR/validate-release" <<'EOF'
#!/bin/bash
printf 'validate-release %s\n' "$*" >> "$SHIP_TEST_LOG"
EOF

cat > "$TEST_DIR/validate-appcast" <<'EOF'
#!/bin/bash
printf 'validate-appcast %s\n' "$*" >> "$SHIP_TEST_LOG"
EOF
chmod +x "$BIN_DIR/git" "$BIN_DIR/gh" "$BIN_DIR/curl" \
    "$TEST_DIR/validate-release" "$TEST_DIR/validate-appcast"

run_ship() {
    PATH="$BIN_DIR:$PATH" \
        SHIP_TEST_LOG="$LOG_PATH" \
        BUILD_DIR="$BUILD_DIR" \
        VALIDATE_RELEASE_SCRIPT="$TEST_DIR/validate-release" \
        VALIDATE_APPCAST_SCRIPT="$TEST_DIR/validate-appcast" \
        "$@"
}

MANUAL_APPCAST="$TEST_DIR/manual-appcast.xml"
printf '<rss><channel></channel></rss>\n' > "$MANUAL_APPCAST"
run_ship env RELEASE_CHANNEL=manual ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1 \
    APPCAST_PATH="$MANUAL_APPCAST" bash scripts/ship.sh 1.2.3

grep -F "validate-release 1.2.3 $DMG_PATH" "$LOG_PATH" >/dev/null
! grep -F 'validate-appcast' "$LOG_PATH" >/dev/null
grep -F "gh release create v1.2.3 $DMG_PATH $CHECKSUM_PATH" "$LOG_PATH" >/dev/null
grep -F "curl --fail --location --head --retry 5 --retry-delay 2 https://github.com/himudigonda/Voqora/releases/download/v1.2.3/Voqora-1.2.3.dmg.sha256" "$LOG_PATH" >/dev/null

# A manual release is forbidden from becoming an accidental Sparkle update,
# even if a maintainer has already added the DMG to the appcast.
printf '%s\n' '<enclosure url="Voqora-1.2.3.dmg"/>' > "$MANUAL_APPCAST"
if run_ship env RELEASE_CHANNEL=manual ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1 \
    APPCAST_PATH="$MANUAL_APPCAST" bash scripts/ship.sh 1.2.3 >/dev/null 2>&1; then
    echo "Manual release unexpectedly accepted an appcast entry." >&2
    exit 1
fi

if run_ship env RELEASE_CHANNEL=manual ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1 \
    APPCAST_PATH="$TEST_DIR/missing-appcast.xml" bash scripts/ship.sh 1.2.3 >/dev/null 2>&1; then
    echo "Manual release unexpectedly accepted a missing prior appcast." >&2
    exit 1
fi

# The notarized channel retains the Sparkle validation path and never permits
# the manual opt-in switch.
: > "$LOG_PATH"
NOTARIZED_APPCAST="$TEST_DIR/notarized-appcast.xml"
printf '%s\n' '<enclosure url="Voqora-1.2.3.dmg"/>' > "$NOTARIZED_APPCAST"
run_ship env RELEASE_CHANNEL=notarized APPCAST_PATH="$NOTARIZED_APPCAST" \
    bash scripts/ship.sh 1.2.3
grep -F "validate-appcast 1.2.3 $DMG_PATH $NOTARIZED_APPCAST" "$LOG_PATH" >/dev/null
grep -F "gh release create v1.2.3 $DMG_PATH $CHECKSUM_PATH" "$LOG_PATH" >/dev/null

# Unknown values must fail before any upload-capable command runs.
if run_ship env RELEASE_CHANNEL=unsafe bash scripts/ship.sh 1.2.3 >/dev/null 2>&1; then
    echo "Unknown release channel unexpectedly succeeded." >&2
    exit 1
fi

echo "✅ Release channel guards passed."
