#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?Usage: verify-app.sh /path/to/AgentUsage.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/AgentUsage"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
CLAUDE_HELPER="$APP_PATH/Contents/Helpers/AgentUsageClaudeHelper"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
test -x "$EXECUTABLE"
test -x "$CLAUDE_HELPER"
test -d "$SPARKLE_FRAMEWORK"
codesign --verify --strict --verbose=2 "$CLAUDE_HELPER"

otool -L "$EXECUTABLE" | grep -F "@rpath/Sparkle.framework/Versions/B/Sparkle" >/dev/null
otool -l "$EXECUTABLE" | grep -F "@executable_path/../Frameworks" >/dev/null

DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1)"
if [[ "$DESIGNATED_REQUIREMENT" == *"cdhash H\""* ]]; then
  echo "AgentUsage has an unstable CDHash-only designated requirement." >&2
  exit 1
fi
if [[ "$DESIGNATED_REQUIREMENT" != *'identifier "io.github.rock-z.agentusage"'* \
  || "$DESIGNATED_REQUIREMENT" != *"certificate root = H\""* ]]
then
  echo "AgentUsage designated requirement is not anchored to its persistent certificate." >&2
  exit 1
fi

test "$(plutil -extract SUFeedURL raw "$INFO_PLIST")" \
  = "https://github.com/Rock-Z/AgentUsage/releases/latest/download/appcast.xml"
test -n "$(plutil -extract SUPublicEDKey raw "$INFO_PLIST")"
test "$(plutil -extract SUEnableAutomaticChecks raw "$INFO_PLIST")" = "true"
test "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$INFO_PLIST")" = "true"

"$EXECUTABLE" --self-test
echo "Verified $APP_PATH"
