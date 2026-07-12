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
#   3. KNOWN GAP (documented, not fixed here — see below): the shim's
#      packaged-app SDK lookup (find_obs_sdk_dir() in rewind_obs.c,
#      dladdr-based) assumed the compiled shim would be a flat dylib
#      directly in Contents/Frameworks/, so "<shim dir>/../Resources/obs"
#      would resolve to Contents/Resources/obs. In practice the
#      Dart/Flutter macOS build toolchain wraps the shim code asset in its
#      own nested framework bundle instead
#      (Contents/Frameworks/rewind_obs.framework/Versions/A/rewind_obs), so
#      that same relative expression actually resolves to
#      Contents/Frameworks/rewind_obs.framework/Versions/Resources/obs — two
#      directory levels off from where this script puts the SDK below.
#      A symlink bridging the two was tried and rejected: injecting extra
#      content inside a framework bundle breaks `codesign --deep` ("unsealed
#      contents present in the root directory of an embedded framework").
#      Fixing this for real needs a small rewind_obs.c change (try an extra
#      "../../../Resources/obs" candidate, or better, resolve the main
#      bundle's Resources dir via NSBundle instead of relative dladdr math)
#      — out of this script's file scope; flagged for a follow-up task.
#      Practical effect: a truly relocated app (moved outside the source
#      tree) will fail SDK lookup via this branch. The dev-tree walk-up
#      fallback in find_obs_sdk_dir() still works for builds run from
#      inside the repo (build/macos/Build/Products/**), which is what this
#      script's own verification exercises.
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

# --- Known gap check (see header comment #3): warn if the shim was built
# as a nested framework, since its packaged-app SDK lookup won't resolve
# Contents/Resources/obs in that layout for a truly relocated app. Not
# fixed here (would require modifying rewind_obs.c) — the dev-tree walk-up
# fallback still covers builds run from inside the repo.
SHIM_FRAMEWORK="$FRAMEWORKS/rewind_obs.framework"
if [[ -d "$SHIM_FRAMEWORK/Versions" ]]; then
  echo "warning: rewind_obs shim is a nested framework bundle; its packaged-app" >&2
  echo "         SDK lookup (dladdr-based, see rewind_obs.c) will NOT find" >&2
  echo "         $RESOURCES_OBS if this app is moved outside the source tree." >&2
  echo "         See this script's header comment for details/follow-up." >&2
elif [[ -f "$FRAMEWORKS/rewind_obs.dylib" || -f "$FRAMEWORKS/librewind_obs.dylib" ]]; then
  # Flat-dylib layout (if a future toolchain change stops wrapping the code
  # asset in its own framework) — "<shim dir>/../Resources/obs" already
  # resolves to Contents/Resources/obs directly; no gap in that case.
  echo "==> Shim is a flat dylib; packaged-app SDK lookup resolves correctly"
else
  echo "warning: could not locate the built rewind_obs shim under $FRAMEWORKS" \
       "to check its SDK lookup path" >&2
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

echo "==> Ad-hoc re-signing $APP_PATH"
codesign --force --deep -s - "$APP_PATH"

echo "==> Done. libobs runtime bundled into $APP_PATH"
