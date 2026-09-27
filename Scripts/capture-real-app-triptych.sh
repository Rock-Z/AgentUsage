#!/usr/bin/env bash
set -euo pipefail

# Captures the real AgentUsage menu bar icon and popover on the main display
# over three demo wallpapers, then composes the README triptych. Any display
# arrangement works: capture rects come from the live window positions.
#
# Requires Accessibility and Screen Recording permission for the terminal, and
# the AgentUsage icon visible in the menu bar with the Options section collapsed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/Assets/Previews/agent-usage-real-app-triptych.png}"
CAPTURE_DIR="$ROOT_DIR/Assets/Previews/real-app-captures"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentusage-real-triptych.XXXXXX")"
BACKGROUND_BINARY="$TEMP_DIR/agentusage-demo-background"
APP_PATH="${AGENTUSAGE_APP_PATH:-/Applications/AgentUsage.app}"
BACKGROUND_PID=""

cleanup() {
    if [[ -n "$BACKGROUND_PID" ]]; then
        kill "$BACKGROUND_PID" 2>/dev/null || true
        wait "$BACKGROUND_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
    echo "Installed app not found at $APP_PATH" >&2
    exit 1
fi

export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/codex-bar-clang-cache}"

swiftc "$ROOT_DIR/Scripts/real-demo-background.swift" -o "$BACKGROUND_BINARY"
mkdir -p "$CAPTURE_DIR" "$(dirname "$OUTPUT_PATH")"
open -g "$APP_PATH"
sleep 1

open_popover() {
    "$BACKGROUND_BINARY" close-popover
    "$BACKGROUND_BINARY" click-primary-status
    sleep 0.6
    if ! "$BACKGROUND_BINARY" assert-primary-popover; then
        echo "The AgentUsage popover did not open on the main display." >&2
        exit 1
    fi
}

select_chart() {
    local period="$1"
    open_popover
    # The period selector is a row of buttons named Day, Week, and Cumulative.
    osascript \
        -e "tell application \"System Events\" to tell process \"AgentUsage\"" \
        -e "repeat with element in (entire contents of window 1)" \
        -e "try" \
        -e "if role of element is \"AXButton\" and (name of element is \"$period\" or description of element is \"$period\") then" \
        -e "click element" \
        -e "exit repeat" \
        -e "end if" \
        -e "end try" \
        -e "end repeat" \
        -e "end tell"
    sleep 0.4
    "$BACKGROUND_BINARY" close-popover
}

capture_state() {
    local period="$1"
    local style="$2"
    local name="$3"

    select_chart "$period"
    "$BACKGROUND_BINARY" "$style" >"$TEMP_DIR/background-$name.log" 2>&1 &
    BACKGROUND_PID="$!"
    sleep 0.8

    open_popover
    # Let the popover finish appearing and the charts settle.
    sleep 1.2
    local geometry
    geometry="$("$BACKGROUND_BINARY" geometry)"
    local status_rect popover_rect
    status_rect="$(sed -n 1p <<<"$geometry")"
    popover_rect="$(sed -n 2p <<<"$geometry")"
    screencapture -x -R "$status_rect" "$TEMP_DIR/$name-status.png"
    screencapture -x -R "$popover_rect" "$TEMP_DIR/$name-popover.png"
    "$BACKGROUND_BINARY" close-popover

    kill "$BACKGROUND_PID" 2>/dev/null || true
    wait "$BACKGROUND_PID" 2>/dev/null || true
    BACKGROUND_PID=""

    for part in status popover; do
        if [[ ! -s "$TEMP_DIR/$name-$part.png" ]]; then
            echo "Capture was not created: $name-$part.png" >&2
            exit 1
        fi
        cp "$TEMP_DIR/$name-$part.png" "$CAPTURE_DIR/$name-$part.png"
    done
}

capture_state Day light day
capture_state Week mixed week
capture_state Cumulative dark cumulative

swift "$ROOT_DIR/Scripts/compose-real-app-triptych.swift" \
    "$CAPTURE_DIR/day-status.png" "$CAPTURE_DIR/day-popover.png" \
    "$CAPTURE_DIR/week-status.png" "$CAPTURE_DIR/week-popover.png" \
    "$CAPTURE_DIR/cumulative-status.png" "$CAPTURE_DIR/cumulative-popover.png" \
    "$OUTPUT_PATH"
