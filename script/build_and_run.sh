#!/usr/bin/env bash
set -euo pipefail

# One deliberate local run loop for Voqora. It builds the bundled speech
# service and Release app, then launches the newly built bundle only when no
# other Voqora copy owns the shared product profile or local speech port. It
# never starts a macOS test host and never terminates another app for a build.

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Voqora"
APP_PATH="$ROOT_DIR/build/DerivedData/Build/Products/Release/$APP_NAME.app"
BUNDLE_ID="com.himudigonda.Voqora"

cd "$ROOT_DIR"

assert_runtime_is_exclusive() {
  # Public and source builds deliberately use one bundle identifier so macOS
  # permissions and application data stay coherent for real updates. That also
  # means a local candidate must never be launched beside an installed copy:
  # both would target the same extracted backend and loopback port. Refuse the
  # overlap with a useful message instead of forcibly killing either app.
  if /usr/bin/pgrep -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "An installed Voqora is running. Quit it before launching a local candidate; this runner will not stop it for you." >&2
    exit 2
  fi

  if /usr/bin/pgrep -f "$APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "A local Voqora candidate is already running. Quit it before starting another one." >&2
    exit 2
  fi

  if /usr/bin/pgrep -f "$HOME/Library/Application Support/$BUNDLE_ID/VoqoraServer/VoqoraServer" >/dev/null 2>&1; then
    echo "A Voqora local speech service is already running. Quit its owning Voqora app and wait for it to exit before retrying." >&2
    exit 2
  fi
}

# An AD-HOC signed build gets a new code-signing designated requirement every
# time it is built, and macOS records the Accessibility grant against that
# requirement — so the old grant silently stops applying while System Settings
# still shows the toggle "on" and `AXIsProcessTrusted()` returns false. The
# only honest recovery in that case is to clear the stale grant so the next
# launch produces a real prompt.
#
# That is no longer the default: `make app` signs with a stable identity
# (LOCAL_SIGN_IDENTITY), which keeps the requirement constant across rebuilds,
# so a grant given once keeps working and must NOT be reset — resetting it is
# exactly the "delete the old one and re-add it every time" loop we are trying
# to get rid of. So only reset when the build actually came out ad-hoc.
reset_dev_accessibility() {
  local requirement
  requirement="$(/usr/bin/codesign -d -r- "$APP_PATH" 2>/dev/null || true)"

  if printf '%s' "$requirement" | /usr/bin/grep -q "certificate leaf\[subject.CN\]"; then
    echo "Stable signing identity detected; keeping your existing Accessibility grant."
    echo "(Grant it once if prompted — it will survive future rebuilds.)"
    return 0
  fi

  echo "Ad-hoc signature detected: resetting Accessibility for $BUNDLE_ID so the next launch prompts properly."
  echo "To stop this happening every build, see LOCAL_SIGN_IDENTITY in the Makefile."
  /usr/bin/tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
}

build_latest() {
  make backend
  make app
  reset_dev_accessibility
}

launch_app() {
  /usr/bin/open "$APP_PATH"
}

# `pgrep -x Voqora` is not enough when an older copy happens to live in
# /Applications. Prove that the process came from the bundle we just built.
is_exact_app_running() {
  /usr/bin/pgrep -f "$APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1
}

# A process is not a usable app until its bundled local service has loaded.
#
# v1.2.3 replaced the fixed port with an app-owned ephemeral socket handed to
# the child as fd 0, behind a per-launch token, so readiness is read from the
# process tree rather than an HTTP probe.
is_bundled_backend_ready() {
  local backend_pid
  backend_pid="$(/usr/bin/pgrep -f "$BUNDLE_ID/VoqoraServer/VoqoraServer" 2>/dev/null | /usr/bin/head -1)"
  [ -n "$backend_pid" ] || return 1

  /usr/sbin/lsof -a -nP -p "$backend_pid" -iTCP -sTCP:LISTEN >/dev/null 2>&1 || return 1

  # The model load is what "ready" means; the backend announces it on stdout.
  local log="$HOME/Library/Application Support/$BUNDLE_ID/frontend.log"
  [ -f "$log" ] || return 1
  /usr/bin/grep -q "startup.engine_load.ready" "$log"
}

verify_fresh_launch() {
  # Cold model loading can take longer than a process spawn, especially after
  # a fresh backend extraction. Sixty seconds is a clear, bounded diagnosis.
  for _ in {1..240}; do
    if is_exact_app_running && is_bundled_backend_ready; then
      echo "Verified: the freshly built $APP_NAME bundle and its local speech service are ready."
      return 0
    fi
    sleep 0.25
  done

  echo "The freshly built $APP_NAME bundle did not become ready within 60 seconds." >&2
  echo "Inspect: $HOME/Library/Application Support/$BUNDLE_ID/frontend.log" >&2
  echo "Inspect: $HOME/Library/Application Support/$BUNDLE_ID/backend.log" >&2
  return 1
}

case "$MODE" in
  run)
    assert_runtime_is_exclusive
    build_latest
    launch_app
    ;;
  --debug|debug)
    assert_runtime_is_exclusive
    build_latest
    exec lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    assert_runtime_is_exclusive
    build_latest
    launch_app
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    assert_runtime_is_exclusive
    build_latest
    launch_app
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    assert_runtime_is_exclusive
    build_latest
    launch_app
    verify_fresh_launch
    ;;
  --clean-build|clean-build)
    assert_runtime_is_exclusive
    FORCE_BACKEND_REBUILD=1 build_latest
    launch_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--clean-build]" >&2
    exit 2
    ;;
esac
