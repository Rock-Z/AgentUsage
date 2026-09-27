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

# Binaries linked against an SDK before 26 run in a legacy compatibility
# appearance (no Liquid Glass) on current macOS.
sdk_major="$(otool -l "$EXECUTABLE" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { split($2, v, "."); print v[1]; exit }')"
if [[ -z "$sdk_major" || "$sdk_major" -lt 26 ]]; then
  echo "AgentUsage must be linked against macOS SDK 26 or later (found ${sdk_major:-none})" >&2
  exit 1
fi

echo "Verified $APP_PATH"
