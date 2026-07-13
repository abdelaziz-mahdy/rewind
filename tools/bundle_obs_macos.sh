#!/usr/bin/env bash
# Bundles the fetched libobs SDK (native/third_party/obs/, see
# tools/fetch_libobs.sh) into a built rewind.app so it's a self-contained,
# relocatable package that doesn't depend on the source tree at runtime.
#
# Usage:
#   tools/bundle_obs_macos.sh <path-to-rewind.app>
#   e.g. tools/bundle_obs_macos.sh build/macos/Build/Products/Debug/rewind.app
#
# What it does:
#   1. Copies native/third_party/obs/lib/* (libobs.framework + the
#      libobs-opengl/FFmpeg/x264/mbedTLS dylib closure) into
#      Contents/Frameworks/.
#   2. Copies native/third_party/obs/{obs-plugins,data}/ into
#      Contents/Resources/obs/{obs-plugins,data}/ — the layout
#      native/shim/rewind_obs.c's setup_module_paths() expects.
#   3. Copies bin/obs-ffmpeg-mux next to the main executable — obs-ffmpeg
#      spawns it to write replay files (see comment at the copy below).
#      (The shim's packaged-app SDK lookup handles the nested-framework
#      layout since the find_graphics_module_path/candidate fixes in
#      rewind_obs.c; the historical gap notes live in git history.)
#   4. Adds a defense-in-depth rpath to the app's main executable and
#      ad-hoc re-signs the app (codesign --force --deep -s -) since adding
#      files invalidates any existing signature. Ad-hoc only; real
#      signing/notarization is out of scope for v0.1 (see ROADMAP.md).
#
# Idempotent: safe to re-run against the same .app (overwrites prior copies).
set -euo pipefail

APP_PATH="${1:?usage: tools/bundle_obs_macos.sh <path-to-rewind.app>}"
APP_PATH="${APP_PATH%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_DIR="$REPO_ROOT/native/third_party/obs"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  exit 1
fi
if [[ ! -d "$SDK_DIR/obs-plugins" ]]; then
  echo "error: libobs SDK not found at $SDK_DIR (run tools/fetch_libobs.sh first)" >&2
  exit 1
fi

CONTENTS="$APP_PATH/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES_OBS="$CONTENTS/Resources/obs"

echo "==> Copying libobs runtime (framework + dylib closure) into $FRAMEWORKS"
mkdir -p "$FRAMEWORKS"
for item in "$SDK_DIR"/lib/*; do
  rm -rf "$FRAMEWORKS/$(basename "$item")"
  cp -R "$item" "$FRAMEWORKS/"
done

echo "==> Copying obs-plugins/ and data/ into $RESOURCES_OBS"
mkdir -p "$RESOURCES_OBS"
rm -rf "$RESOURCES_OBS/obs-plugins" "$RESOURCES_OBS/data"
cp -R "$SDK_DIR/obs-plugins" "$RESOURCES_OBS/obs-plugins"
cp -R "$SDK_DIR/data" "$RESOURCES_OBS/data"

# The replay buffer writes files by spawning the obs-ffmpeg-mux helper,
# which obs-ffmpeg resolves NEXT TO THE MAIN EXECUTABLE
# (os_get_executable_path_ptr). Without it every save fails with
# "Failed to create process pipe" and no file is ever written.
if [[ -x "$SDK_DIR/bin/obs-ffmpeg-mux" ]]; then
  echo "==> Copying obs-ffmpeg-mux helper into $CONTENTS/MacOS/"
  cp "$SDK_DIR/bin/obs-ffmpeg-mux" "$CONTENTS/MacOS/"
else
  echo "error: $SDK_DIR/bin/obs-ffmpeg-mux missing — re-run tools/fetch_libobs.sh" >&2
  exit 1
fi

# --- Defense-in-depth rpath on the main app binary. The shim itself is
# compiled with its own correct rpaths (see hook/build.dart); this covers
# any dyld @rpath resolution that also consults the loading chain's rpaths.
APP_BINARY="$CONTENTS/MacOS/$(basename "$APP_PATH" .app)"
if [[ -x "$APP_BINARY" ]]; then
  if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
    echo "==> Adding @executable_path/../Frameworks rpath to $APP_BINARY"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
  fi
else
  echo "warning: app binary not found/executable at $APP_BINARY" >&2
fi

# Sign with the same identity Xcode uses (EXPANDED_CODE_SIGN_IDENTITY is set
# inside build phases), so the app keeps ONE stable signature and macOS TCC
# grants (Screen Recording) survive rebuilds. Ad-hoc only as a last resort
# for manual invocations outside a build.
SIGN_ID="${REWIND_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
echo "==> Re-signing $APP_PATH (identity: $SIGN_ID)"
codesign --force --deep -s "$SIGN_ID" "$APP_PATH"

echo "==> Done. libobs runtime bundled into $APP_PATH"
