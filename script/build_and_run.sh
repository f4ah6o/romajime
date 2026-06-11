#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -d Romajime.xcodeproj ]]; then
  xcodegen generate
fi

/usr/bin/pkill -x Romajime 2>/dev/null || true
xcodebuild -scheme Romajime -project Romajime.xcodeproj -configuration Debug -derivedDataPath "$ROOT_DIR/DerivedData" build

APP_PATH="$ROOT_DIR/build/Debug/Romajime.app"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$ROOT_DIR/DerivedData/Build/Products/Debug/Romajime.app"
fi

case "${1:-}" in
  --verify)
    /usr/bin/open -n "$APP_PATH"
    sleep 1
    /usr/bin/pgrep -x Romajime >/dev/null
    ;;
  --logs)
    /usr/bin/open -n "$APP_PATH"
    /usr/bin/log stream --style compact --predicate 'process == "Romajime"'
    ;;
  *)
    /usr/bin/open -n "$APP_PATH"
    ;;
esac
