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

# Wake the display and keep it awake for the duration of the test — a
# sleeping display records as faithful black frames and fails the pixel
# check with a misleading verdict. 70s (not 45s): the app now stays alive
# through the thumbnail poll below (moved after this point so real libmpv
# thumbnail generation — which runs in-process — has time to finish before
# pkill tears the app down).
caffeinate -d -u -t 70 &
CAFF_PID=$!
trap 'kill $CAFF_PID 2>/dev/null || true' EXIT

pkill -x rewind 2>/dev/null && sleep 1 || true
mkdir -p "$CLIPS_DIR"

# "Only record while playing" defaults ON (2026-07-18), which pauses the
# replay buffer whenever no game is detected — including during this test.
# Without forcing it off, the .save-now leg silently saves nothing (the
# buffer output stops a few frames after startup) and the recording leg's
# file used to mask that from the "new clip appeared" check below. Force
# always-on buffering for the test run and restore the user's settings after.
SETTINGS="$HOME/Library/Application Support/com.zcreations.rewind/settings.json"
SETTINGS_BAK=""
if [[ -f "$SETTINGS" ]]; then
  SETTINGS_BAK="$(mktemp /tmp/rewind_e2e_settings.XXXXXX)"
  cp "$SETTINGS" "$SETTINGS_BAK"
  python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["captureOnlyInGame"] = False
json.dump(s, open(p, "w"))
PY
else
  mkdir -p "$(dirname "$SETTINGS")"
  printf '{"captureOnlyInGame": false}' > "$SETTINGS"
fi
restore_settings() {
  if [[ -n "$SETTINGS_BAK" ]]; then cp "$SETTINGS_BAK" "$SETTINGS"; rm -f "$SETTINGS_BAK";
  else rm -f "$SETTINGS"; fi
}
trap 'restore_settings; kill $CAFF_PID 2>/dev/null || true' EXIT

# The replay (.save-now) leg must be judged on NON-recording clips only —
# rewind-rec-*.mp4 comes from the recording leg and previously satisfied the
# same *.mp4 glob, letting a dead replay buffer pass the whole test.
count_replay_clips() { ls "$CLIPS_DIR"/*.mp4 2>/dev/null | grep -cv 'rewind-rec-' || true; }
BEFORE_COUNT=$(count_replay_clips)

echo "==> Launching $APP (log: $LOG)"
open --stdout "$LOG" --stderr "$LOG" "$APP"
sleep 12   # let init + the replay buffer accumulate some frames

echo "==> Triggering a save via the debug file trigger"
touch "$CLIPS_DIR/.save-now"
sleep 12   # save is async; generous bound

echo "==> Recording leg: start, wait, stop via the debug toggle"
REC_BEFORE=$(ls "$CLIPS_DIR"/rewind-rec-*.mp4 2>/dev/null | wc -l | tr -d ' ')
touch "$CLIPS_DIR/.record-toggle"
sleep 6
touch "$CLIPS_DIR/.record-toggle"
sleep 8   # stop + muxer finalize + index

# NOTE: pkill is deliberately deferred until after the thumbnail poll below
# — thumbnail generation runs in-process (headless media_kit/libmpv) after
# a clip is indexed, so killing the app too early would race it.

REC_AFTER=$(ls "$CLIPS_DIR"/rewind-rec-*.mp4 2>/dev/null | wc -l | tr -d ' ')
[[ "$REC_AFTER" -gt "$REC_BEFORE" ]] || fail "manual recording produced no rewind-rec-*.mp4 (see $LOG)"
REC=$(ls -t "$CLIPS_DIR"/rewind-rec-*.mp4 | head -1)
if command -v ffprobe >/dev/null 2>&1; then
  RDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$REC")
  awk -v d="$RDUR" 'BEGIN { exit !(d > 2) }' || fail "recording too short (${RDUR}s)"
  echo "==> Recording leg passed ($REC, ${RDUR}s)"
fi

# --- Assertions -----------------------------------------------------------
if grep -q "Failed to create process pipe" "$LOG"; then
  fail "obs-ffmpeg-mux pipe failure in log (helper missing/broken)"
fi
if grep -qiE "permission is not granted|check if OBS has necessary screen capture permissions" "$LOG"; then
  fail "Screen Recording permission not effective for this launch (grant it to rewind.app and relaunch)"
fi

AFTER_COUNT=$(count_replay_clips)
[[ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]] || fail "replay-buffer save produced no new clip in $CLIPS_DIR (buffer dead or paused? see $LOG)"
CLIP=$(ls -t "$CLIPS_DIR"/*.mp4 | grep -v 'rewind-rec-' | head -1)
echo "==> New replay clip: $CLIP"

if command -v ffprobe >/dev/null 2>&1; then
  DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CLIP")
  awk -v d="$DURATION" 'BEGIN { exit !(d > 1) }' || fail "clip too short (${DURATION}s)"
  # Mean luma across sampled frames: pure black encodes ≈ 16 (limited range).
  # metadata=print logs at info level (silenced by -v error); file=- routes
  # the stats to stdout regardless of loglevel.
  LUMA=$(ffmpeg -v error -i "$CLIP" -vf "select=not(mod(n\,30)),signalstats,metadata=print:file=-" -f null - 2>/dev/null \
    | awk -F= '/YAVG/ { sum += $2; n++ } END { if (n) printf "%.1f", sum / n; else print 0 }')
  awk -v l="$LUMA" 'BEGIN { exit !(l > 20) }' || fail "clip appears to be black frames (mean luma $LUMA — permission or capture-source problem)"
  echo "==> Pixel check passed (duration ${DURATION}s, mean luma $LUMA)"
else
  echo "warning: ffprobe not found — skipping duration/pixel checks" >&2
fi

# --- Thumbnail check --------------------------------------------------------
# The one place thumbnail generation is exercised through the REAL libmpv
# backend (widget/unit tests only ever fake the ThumbnailGenerator seam).
# The app is still running at this point (pkill is below) so the
# fire-and-forget generation kicked off when $CLIP was indexed has a real
# chance to finish.
echo "==> Waiting for the thumbnail of $CLIP"
THUMB="$(dirname "$CLIP")/.thumbs/$(basename "$CLIP" .mp4).jpg"
THUMB_DEADLINE=$((SECONDS + 15))
while [[ ! -f "$THUMB" ]] && [[ $SECONDS -lt $THUMB_DEADLINE ]]; do
  sleep 1
done
[[ -f "$THUMB" ]] || fail "thumbnail not generated within 15s: $THUMB (see $LOG)"
THUMB_SIZE=$(stat -f%z "$THUMB" 2>/dev/null || stat -c%s "$THUMB" 2>/dev/null)
[[ "$THUMB_SIZE" -gt 1024 ]] || fail "thumbnail suspiciously small (${THUMB_SIZE} bytes): $THUMB"
echo "==> Thumbnail check passed ($THUMB, ${THUMB_SIZE} bytes)"

pkill -x rewind 2>/dev/null || true

echo "E2E PASS: $CLIP"
