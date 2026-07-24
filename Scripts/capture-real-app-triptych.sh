#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/Assets/Previews/agent-usage-real-app-triptych.png}"
CAPTURE_DIR="$ROOT_DIR/Assets/Previews/real-app-captures"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentusage-real-triptych.XXXXXX")"
BACKGROUND_BINARY="$TEMP_DIR/agentusage-demo-background"
SNIPASTE="/Applications/Snipaste.app/Contents/MacOS/Snipaste"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
APP_PATH="${AGENTUSAGE_APP_PATH:-$HOME/Applications/AgentUsage.app}"
PRIMARY_CROP="${AGENTUSAGE_PRIMARY_CROP:-3600x2338+1008+2592}"
BACKGROUND_PID=""

cleanup() {
    if [[ -n "$BACKGROUND_PID" ]]; then
        kill "$BACKGROUND_PID" 2>/dev/null || true
        wait "$BACKGROUND_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ ! -x "$SNIPASTE" ]]; then
    echo "Snipaste is required at $SNIPASTE" >&2
    exit 1
fi
if [[ ! -x "$MAGICK" ]]; then
    echo "ImageMagick is required at $MAGICK" >&2
    exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
    echo "Installed app not found at $APP_PATH" >&2
    exit 1
fi

export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/codex-bar-clang-cache}"

swiftc "$ROOT_DIR/Scripts/real-demo-background.swift" -o "$BACKGROUND_BINARY"
mkdir -p "$CAPTURE_DIR" "$(dirname "$OUTPUT_PATH")"
open -g "$APP_PATH"
sleep 1

select_chart() {
    local index="$1"
    "$BACKGROUND_BINARY" close-popover
    "$BACKGROUND_BINARY" click-primary-status
    sleep 0.4
    "$BACKGROUND_BINARY" assert-primary-popover
    osascript \
        -e "tell application \"System Events\" to tell process \"AgentUsage\" to click radio button $index of radio group 1 of group 1 of window 1"
    sleep 0.2
    "$BACKGROUND_BINARY" close-popover
}

capture_state() {
    local index="$1"
    local style="$2"
    local name="$3"
    local capture_path="$TEMP_DIR/$name.png"
    local full_capture_path="$TEMP_DIR/$name-full.png"

    select_chart "$index"
    "$BACKGROUND_BINARY" "$style" >"$TEMP_DIR/background-$name.log" 2>&1 &
    BACKGROUND_PID="$!"
    sleep 0.5

    # Snipaste's area coordinates become ambiguous in a mixed-DPI display
    # arrangement. Capture the whole virtual desktop, then crop the 2x primary
    # display deterministically.
    "$SNIPASTE" snip --full --delay 3 -o "$full_capture_path"
    "$BACKGROUND_BINARY" click-primary-status
    sleep 0.4
    "$BACKGROUND_BINARY" assert-primary-popover
    capture_ready=false
    previous_size=0
    stable_checks=0
    for _ in {1..20}; do
        current_size=0
        if [[ -f "$full_capture_path" ]]; then
            current_size="$(stat -f %z "$full_capture_path")"
        fi
        if (( current_size > 500000 && current_size == previous_size )); then
            ((stable_checks += 1))
        else
            stable_checks=0
        fi
        if (( stable_checks >= 2 )); then
            capture_ready=true
            break
        fi
        previous_size="$current_size"
        sleep 0.5
    done
    if [[ "$capture_ready" != true ]]; then
        echo "Timed out waiting for Snipaste to finish: $full_capture_path" >&2
        exit 1
    fi
    "$BACKGROUND_BINARY" close-popover
    "$MAGICK" "$full_capture_path" \
        -crop "$PRIMARY_CROP" +repage \
        "$capture_path"

    kill "$BACKGROUND_PID" 2>/dev/null || true
    wait "$BACKGROUND_PID" 2>/dev/null || true
    BACKGROUND_PID=""

    if [[ ! -s "$capture_path" ]]; then
        echo "Capture was not created: $capture_path" >&2
        exit 1
    fi
    cp "$capture_path" "$CAPTURE_DIR/$name.png"
}

capture_state 1 light day
capture_state 2 mixed week
capture_state 3 dark cumulative

swift "$ROOT_DIR/Scripts/compose-real-app-triptych.swift" \
    "$CAPTURE_DIR/day.png" \
    "$CAPTURE_DIR/week.png" \
    "$CAPTURE_DIR/cumulative.png" \
    "$OUTPUT_PATH"
