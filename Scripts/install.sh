#!/usr/bin/env bash
set -euo pipefail

APP_NAME="aiusage"
REPOSITORY="${AIUSAGE_REPO:-Rock-Z/aiusage}"
VERSION="${AIUSAGE_VERSION:-latest}"
INSTALL_DIR="${AIUSAGE_INSTALL_DIR:-$HOME/Applications}"
ARCHIVE_NAME="aiusage-macos-universal.zip"

if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository: $REPOSITORY" >&2
  exit 1
fi

for command in curl ditto shasum codesign spctl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ -n "${AIUSAGE_RELEASE_BASE_URL:-}" ]]; then
  RELEASE_URL="${AIUSAGE_RELEASE_BASE_URL%/}"
elif [[ "$VERSION" == "latest" ]]; then
  RELEASE_URL="https://github.com/$REPOSITORY/releases/latest/download"
else
  RELEASE_URL="https://github.com/$REPOSITORY/releases/download/$VERSION"
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-install.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

ARCHIVE_PATH="$TEMP_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

echo "Downloading aiusage ${VERSION}…"
curl --fail --location --silent --show-error --retry 3 \
  "$RELEASE_URL/$ARCHIVE_NAME" --output "$ARCHIVE_PATH"
curl --fail --location --silent --show-error --retry 3 \
  "$RELEASE_URL/$ARCHIVE_NAME.sha256" --output "$CHECKSUM_PATH"

(
  cd "$TEMP_DIR"
  shasum -a 256 -c "$ARCHIVE_NAME.sha256"
)

EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_DIR"

SOURCE_APP="$EXTRACT_DIR/$APP_NAME.app"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Release archive does not contain $APP_NAME.app" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
if [[ "${AIUSAGE_ALLOW_UNNOTARIZED:-0}" != "1" ]]; then
  spctl --assess --type execute --verbose=2 "$SOURCE_APP"
fi

mkdir -p "$INSTALL_DIR"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
STAGING_APP="$INSTALL_DIR/.$APP_NAME.app.installing"
BACKUP_APP="$INSTALL_DIR/.$APP_NAME.app.previous"

rm -rf "$STAGING_APP" "$BACKUP_APP"
ditto "$SOURCE_APP" "$STAGING_APP"
if [[ -d "$TARGET_APP" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  mv "$TARGET_APP" "$BACKUP_APP"
fi
if ! mv "$STAGING_APP" "$TARGET_APP"; then
  if [[ -d "$BACKUP_APP" ]]; then
    mv "$BACKUP_APP" "$TARGET_APP"
  fi
  exit 1
fi
rm -rf "$BACKUP_APP"

echo "Installed $TARGET_APP"
if [[ "${AIUSAGE_SKIP_LAUNCH:-0}" != "1" ]]; then
  open "$TARGET_APP"
fi
