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
}

build_latest() {
  make backend
  make app
}

launch_app() {
  /usr/bin/open "$APP_PATH"
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
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        echo "Verified: freshly built $APP_NAME is running."
        exit 0
      fi
      sleep 0.25
    done
    echo "Voqora did not remain running after launch." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
