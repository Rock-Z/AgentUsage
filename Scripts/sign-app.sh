#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${1:?Usage: sign-app.sh /path/to/AgentUsage.app}"
IDENTITY_NAME="${AGENTUSAGE_SIGNING_IDENTITY:-AgentUsage Code Signing}"
SIGNING_KEYCHAIN="${AGENTUSAGE_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/AgentUsage-signing.keychain-db}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PASSWORD_SERVICE="io.github.rock-z.agentusage.release-signing"
ENTITLEMENTS="$SCRIPT_DIR/../Config/AgentUsage.entitlements"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ -f "$SIGNING_KEYCHAIN" ]] \
  && ! security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null \
    | grep -F "\"$IDENTITY_NAME\"" >/dev/null
then
  KEYCHAIN_PASSWORD="$(
    security find-generic-password \
      -w \
      -s "$PASSWORD_SERVICE" \
      -a "keychain-password" \
      "$LOGIN_KEYCHAIN" 2>/dev/null || true
  )"
  if [[ -n "$KEYCHAIN_PASSWORD" ]]; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
  fi
fi

if ! security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null \
  | grep -F "\"$IDENTITY_NAME\"" >/dev/null
then
  if [[ -n "${AGENTUSAGE_SIGNING_IDENTITY:-}" || -f "$SIGNING_KEYCHAIN" ]]; then
    echo "Code-signing identity not found: $IDENTITY_NAME" >&2
    echo "Code-signing password was not found in the login Keychain." >&2
    exit 1
  fi
  IDENTITY_NAME="-"
  echo "Warning: AgentUsage Code Signing identity not found; using an unstable ad-hoc signature." >&2
fi

CODESIGN_KEYCHAIN_ARGS=()
if [[ "$IDENTITY_NAME" != "-" ]]; then
  CODESIGN_KEYCHAIN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
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
        "${CODESIGN_KEYCHAIN_ARGS[@]}" \
        --sign "$IDENTITY_NAME" \
        "$code_path"
    fi
  done
  codesign \
    --force \
    --options runtime \
    --preserve-metadata=identifier,entitlements,flags \
    "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    --sign "$IDENTITY_NAME" \
    "$FRAMEWORK"
fi

CLAUDE_HELPER="$APP_PATH/Contents/Helpers/AgentUsageClaudeHelper"
if [[ -f "$CLAUDE_HELPER" ]]; then
  codesign \
    --force \
    --identifier "io.github.rock-z.agentusage.claude-helper" \
    --options runtime \
    "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    --sign "$IDENTITY_NAME" \
    "$CLAUDE_HELPER"
fi

codesign \
  --force \
  --entitlements "$ENTITLEMENTS" \
  --options runtime \
  "${CODESIGN_KEYCHAIN_ARGS[@]}" \
  --sign "$IDENTITY_NAME" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
