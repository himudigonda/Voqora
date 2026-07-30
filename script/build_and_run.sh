#!/usr/bin/env bash
set -euo pipefail

# One deliberate local run loop for Voqora. It builds the bundled speech
# service and Release app, stops only an existing Voqora process, then launches
# the newly built bundle. It never starts a macOS test host.

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Voqora"
APP_PATH="$ROOT_DIR/build/DerivedData/Build/Products/Release/$APP_NAME.app"
BUNDLE_ID="com.himudigonda.Voqora"

cd "$ROOT_DIR"

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  # The local service is a child of Voqora in normal operation. Stop the
  # explicitly named child too so a rebuilt bundle cannot accidentally reuse
  # a previous process already listening on the local port.
  pkill -x "VoqoraServer" >/dev/null 2>&1 || true
}

build_latest() {
  make backend
  make app
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
# This checks the loopback-only health endpoint without emitting user content
# or talking to a network service.
is_bundled_backend_ready() {
  local health
  health="$(/usr/bin/curl --connect-timeout 1 --max-time 1 --silent --show-error --fail \
    http://127.0.0.1:10101/health 2>/dev/null)" || return 1

  printf '%s' "$health" | /usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"' \
    && printf '%s' "$health" | /usr/bin/grep -Eq '"loaded"[[:space:]]*:[[:space:]]*true'
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
    stop_running_app
    build_latest
    launch_app
    ;;
  --debug|debug)
    stop_running_app
    build_latest
    exec lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    stop_running_app
    build_latest
    launch_app
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_running_app
    build_latest
    launch_app
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_running_app
    build_latest
    launch_app
    verify_fresh_launch
    ;;
  --clean-build|clean-build)
    stop_running_app
    FORCE_BACKEND_REBUILD=1 build_latest
    launch_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--clean-build]" >&2
    exit 2
    ;;
esac
