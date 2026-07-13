#!/usr/bin/env bash
# End-to-end capture smoke test (macOS): launches the REAL bundled app, saves
# a clip via the debug file trigger, and asserts the clip exists, has
# duration, and contains actual (non-black) pixels. Catches the failure
# classes unit tests can't see: missing obs-ffmpeg-mux helper, Screen
# Recording permission problems, black-frame capture, save timeouts.
#
# Usage:
#   tools/e2e_smoke.sh [path-to-rewind.app]     (default: debug build)
#
# Prereqs: a debug build (`flutter build macos --debug` auto-bundles libobs),
# Screen Recording permission granted to rewind.app, ffprobe/ffmpeg on PATH
# for the pixel check (skipped with a warning if absent).
#
# IMPORTANT: launch is via `open` so macOS attributes the Screen Recording
# permission to rewind.app itself — running the binary directly would
# attribute it to your terminal and fail spuriously.
set -euo pipefail

APP="${1:-build/macos/Build/Products/Debug/rewind.app}"
CLIPS_DIR="$HOME/Movies/Rewind"
LOG="$(mktemp /tmp/rewind_e2e.XXXXXX)"

fail() { echo "E2E FAIL: $*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "app not found: $APP (flutter build macos --debug first)"
[[ -x "$APP/Contents/MacOS/obs-ffmpeg-mux" ]] || fail "obs-ffmpeg-mux helper missing from the bundle"

pkill -x rewind 2>/dev/null && sleep 1 || true
mkdir -p "$CLIPS_DIR"
BEFORE_COUNT=$(ls "$CLIPS_DIR"/*.mp4 2>/dev/null | wc -l | tr -d ' ')

echo "==> Launching $APP (log: $LOG)"
open --stdout "$LOG" --stderr "$LOG" "$APP"
sleep 12   # let init + the replay buffer accumulate some frames

echo "==> Triggering a save via the debug file trigger"
touch "$CLIPS_DIR/.save-now"
sleep 12   # save is async; generous bound

pkill -x rewind 2>/dev/null || true

# --- Assertions -----------------------------------------------------------
if grep -q "Failed to create process pipe" "$LOG"; then
  fail "obs-ffmpeg-mux pipe failure in log (helper missing/broken)"
fi
if grep -qiE "permission is not granted|check if OBS has necessary screen capture permissions" "$LOG"; then
  fail "Screen Recording permission not effective for this launch (grant it to rewind.app and relaunch)"
fi

AFTER_COUNT=$(ls "$CLIPS_DIR"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
[[ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]] || fail "no new clip appeared in $CLIPS_DIR (see $LOG)"
CLIP=$(ls -t "$CLIPS_DIR"/*.mp4 | head -1)
echo "==> New clip: $CLIP"

if command -v ffprobe >/dev/null 2>&1; then
  DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CLIP")
  awk -v d="$DURATION" 'BEGIN { exit !(d > 1) }' || fail "clip too short (${DURATION}s)"
  # Mean luma across sampled frames: pure black encodes ≈ 16 (limited range).
  LUMA=$(ffmpeg -v error -i "$CLIP" -vf "select=not(mod(n\,30)),signalstats,metadata=print" -f null - 2>&1 \
    | awk -F= '/YAVG/ { sum += $2; n++ } END { if (n) printf "%.1f", sum / n; else print 0 }')
  awk -v l="$LUMA" 'BEGIN { exit !(l > 20) }' || fail "clip appears to be black frames (mean luma $LUMA — permission or capture-source problem)"
  echo "==> Pixel check passed (duration ${DURATION}s, mean luma $LUMA)"
else
  echo "warning: ffprobe not found — skipping duration/pixel checks" >&2
fi

echo "E2E PASS: $CLIP"
