#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${1:?Usage: sign-app.sh /path/to/AgentUsage.app}"
ENTITLEMENTS="$SCRIPT_DIR/../Config/AgentUsage.entitlements"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FRAMEWORK" ]]; then
  SPARKLE_VERSION="$FRAMEWORK/Versions/B"
  for code_path in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app"
  do
    if [[ -e "$code_path" ]]; then
      codesign \
        --force \
        --options runtime \
        --preserve-metadata=identifier,entitlements,flags \
        --sign - \
        "$code_path"
    fi
  done
  codesign \
    --force \
    --options runtime \
    --preserve-metadata=identifier,entitlements,flags \
    --sign - \
    "$FRAMEWORK"
fi

codesign \
  --force \
  --entitlements "$ENTITLEMENTS" \
  --options runtime \
  --sign - \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
