#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentUsage"
CONFIGURATION="release"
APP_DIR="$ROOT_DIR/.build/$CONFIGURATION/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
ICON_SOURCE="$ROOT_DIR/Assets/AgentUsage.icns"

cd "$ROOT_DIR"
if [[ -n "${AGENTUSAGE_EXECUTABLE:-}" ]]; then
  EXECUTABLE="$AGENTUSAGE_EXECUTABLE"
else
  swift build -c "$CONFIGURATION" --product "$APP_NAME"
  EXECUTABLE="$ROOT_DIR/.build/$CONFIGURATION/$APP_NAME"
fi

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Executable not found: $EXECUTABLE" >&2
  exit 1
fi

if [[ -n "${AGENTUSAGE_CLAUDE_HELPER:-}" ]]; then
  CLAUDE_HELPER="$AGENTUSAGE_CLAUDE_HELPER"
elif [[ -x "$(dirname "$EXECUTABLE")/AgentUsageClaudeHelper" ]]; then
  CLAUDE_HELPER="$(dirname "$EXECUTABLE")/AgentUsageClaudeHelper"
else
  swift build -c "$CONFIGURATION" --product AgentUsageClaudeHelper
  CLAUDE_HELPER="$ROOT_DIR/.build/$CONFIGURATION/AgentUsageClaudeHelper"
fi
if [[ ! -x "$CLAUDE_HELPER" ]]; then
  echo "Claude credential helper not found: $CLAUDE_HELPER" >&2
  exit 1
fi

if [[ -n "${AGENTUSAGE_SPARKLE_FRAMEWORK:-}" ]]; then
  SPARKLE_FRAMEWORK="$AGENTUSAGE_SPARKLE_FRAMEWORK"
else
  SPARKLE_FRAMEWORK="$(dirname "$EXECUTABLE")/Sparkle.framework"
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle framework not found: $SPARKLE_FRAMEWORK" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$HELPERS_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
cp "$CLAUDE_HELPER" "$HELPERS_DIR/AgentUsageClaudeHelper"
if ! otool -l "$MACOS_DIR/$APP_NAME" \
  | grep -F "@executable_path/../Frameworks" >/dev/null
then
  install_name_tool \
    -add_rpath "@executable_path/../Frameworks" \
    "$MACOS_DIR/$APP_NAME"
fi
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Icon not found: $ICON_SOURCE" >&2
  exit 1
fi
cp "$ICON_SOURCE" "$RESOURCES_DIR/AgentUsage.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>AgentUsage</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.rock-z.agentusage</string>
  <key>CFBundleIconFile</key>
  <string>AgentUsage</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AgentUsage</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.4.3</string>
  <key>CFBundleVersion</key>
  <string>9</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUEnableSystemProfiling</key>
  <false/>
  <key>SUFeedURL</key>
  <string>https://github.com/Rock-Z/AgentUsage/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>z0ZEDTHSjxN7x48Jx9hFt8hblll/xhpOuFjzCdp/QOs=</string>
  <key>SUScheduledCheckInterval</key>
  <integer>3600</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
</dict>
</plist>
PLIST

"$ROOT_DIR/Scripts/sign-app.sh" "$APP_DIR"

echo "Built $APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"
  echo "Installed $INSTALL_DIR/$APP_NAME.app"
fi
