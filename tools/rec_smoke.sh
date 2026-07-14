#!/usr/bin/env bash
# Standalone smoke test for the manual-recording native path
# (rewind_start_recording/rewind_stop_recording), independent of the
# Flutter UI — there's no recording trigger wired into the app yet (that's
# the coordinator/UI half of this feature). Compiles tools/rec_smoke.c
# against the shim built into the debug app bundle and runs the resulting
# binary IN PLACE (Contents/MacOS/, next to obs-ffmpeg-mux) so the shim's
# runtime SDK-discovery (find_obs_sdk_dir/find_graphics_module_path, both
# relative to the shim's own bundled location) and the
# obs-ffmpeg-mux-helper lookup (mux_helper_present, relative to the
# CALLING process's own path — see rewind_obs.c) resolve exactly as they
# would for the real app.
#
# Usage: tools/rec_smoke.sh  (after `flutter build macos --debug`)
#
# Note: unlike tools/e2e_smoke.sh, this does NOT launch via `open` — it
# execs the compiled test binary directly from a terminal, so Screen
# Recording permission is attributed to the terminal (see CLAUDE.md's
# capture gotchas), not to a signed app identity. If that attribution
# hasn't been granted, rewind_obs_init fails outright (not a black-frame
# recording) — this script reports that plainly rather than papering over
# it.
set -euo pipefail

APP="build/macos/Build/Products/Debug/rewind.app"
SHIM="$APP/Contents/Frameworks/rewind_obs.framework/Versions/A/rewind_obs"
MUX_HELPER="$APP/Contents/MacOS/obs-ffmpeg-mux"
BIN="$APP/Contents/MacOS/rec_smoke_test"
OUT_DIR="$(mktemp -d /tmp/rewind_rec_smoke.XXXXXX)"

fail() { echo "REC_SMOKE FAIL: $*" >&2; exit 1; }

[[ -f "$SHIM" ]] || fail "shim not found: $SHIM (flutter build macos --debug first)"
[[ -x "$MUX_HELPER" ]] || fail "obs-ffmpeg-mux helper missing from the bundle"

echo "==> Compiling tools/rec_smoke.c against $SHIM"
# The shim's own install name is @rpath-relative (@rpath/rewind_obs.framework/
# rewind_obs — Flutter/Dart's native-assets toolchain sets this, not us), so
# our own binary needs an LC_RPATH pointing at its Frameworks/ directory to
# resolve it at load time; the shim's own baked-in rpaths (see hook/build.dart)
# then take over for ITS dependents (libobs.framework etc).
clang tools/rec_smoke.c "$SHIM" -Wl,-rpath,"$PWD/$APP/Contents/Frameworks" -o "$BIN"
trap 'rm -f "$BIN"' EXIT

# Wake the display for the duration of the test — a sleeping display
# records legitimate black frames (see tools/e2e_smoke.sh).
caffeinate -d -u -t 30 &
CAFF_PID=$!
trap 'kill "$CAFF_PID" 2>/dev/null || true; rm -f "$BIN"' EXIT

echo "==> Running (output dir: $OUT_DIR)"
"$BIN" "$OUT_DIR"
