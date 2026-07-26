#!/usr/bin/env bash
set -euo pipefail

release="https://github.com/Rock-Z/AgentUsage/releases/latest/download"
archive="AgentUsage-macos-universal.zip"
install_dir="$HOME/Applications"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

cd "$temp_dir"
echo "Downloading AgentUsage…"
curl -fL "$release/$archive" -o "$archive"
curl -fL "$release/$archive.sha256" -o "$archive.sha256"
shasum -a 256 -c "$archive.sha256"

ditto -x -k "$archive" extracted
codesign --verify --deep --strict extracted/AgentUsage.app

mkdir -p "$install_dir"
pkill -x AgentUsage >/dev/null 2>&1 || true
rm -rf "$install_dir/AgentUsage.app"
ditto extracted/AgentUsage.app "$install_dir/AgentUsage.app"

echo "Installed $install_dir/AgentUsage.app"
open "$install_dir/AgentUsage.app"
