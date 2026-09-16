#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.codex-local/macos-derived"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/HealthCoachMac.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/HealthCoachMac"

build() {
  xcodebuild -project "$ROOT_DIR/HealthCoach.xcodeproj" \
    -scheme HealthCoachMac \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    build
    open_app
    ;;
  --debug|debug)
    build
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "HealthCoachMac"'
    ;;
  --telemetry|telemetry)
    build
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.marlonjd.HealthCoach.Mac"'
    ;;
  --verify|verify)
    build
    open_app
    sleep 1
    pgrep -x HealthCoachMac >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
