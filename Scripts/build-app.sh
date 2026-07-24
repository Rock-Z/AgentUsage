#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentUsage"
CONFIGURATION="release"
APP_DIR="$ROOT_DIR/.build/$CONFIGURATION/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
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

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"

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
  <string>0.4.0</string>
  <key>CFBundleVersion</key>
  <string>6</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"
  echo "Installed $INSTALL_DIR/$APP_NAME.app"
fi
