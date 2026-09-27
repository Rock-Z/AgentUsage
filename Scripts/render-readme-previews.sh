#!/usr/bin/env bash
set -euo pipefail

# Renders the README triptych offscreen from fixed demo data: no screen
# capture, no mouse, and no real account data. The popover content is the
# app's own views; its glass and the menu bar highlight are imitated.
#
# Extra `swift test` flags can be passed in SWIFT_TEST_FLAGS.
# For an exact capture of the real app instead, see capture-real-app-triptych.sh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/Assets/Previews/agent-usage-real-app-triptych.png}"
RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentusage-previews.XXXXXX")"
trap 'rm -rf "$RENDER_DIR"' EXIT

VERSION="$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$ROOT_DIR/Scripts/build-app.sh")"
read -r -a TEST_FLAGS <<<"${SWIFT_TEST_FLAGS:-}"

cd "$ROOT_DIR"
AGENTUSAGE_PREVIEW_DIR="$RENDER_DIR" AGENTUSAGE_PREVIEW_VERSION="$VERSION" \
    swift test ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} --filter renderReadmePreviews

swift "$ROOT_DIR/Scripts/compose-real-app-triptych.swift" --imitate-glass \
    "$RENDER_DIR/day-status.png" "$RENDER_DIR/day-popover.png" \
    "$RENDER_DIR/week-status.png" "$RENDER_DIR/week-popover.png" \
    "$RENDER_DIR/cumulative-status.png" "$RENDER_DIR/cumulative-popover.png" \
    "$OUTPUT_PATH"
