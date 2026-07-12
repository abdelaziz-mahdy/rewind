#!/usr/bin/env bash
# Build a minimal libobs + capture/encode plugins for Rewind, pinned + cached.
# Result lands in native/third_party/obs/ (git-ignored). Idempotent: skips
# work when the stamp file matches OBS_TAG + build arch + deps version.
#
# macOS only for now (Windows lands in a later task). Requires full Xcode.app
# (not just Command Line Tools) — the pinned obs-studio tree hard-requires
# the Xcode CMake generator on macOS (cmake/macos/compilerconfig.cmake) — plus
# cmake, git, and python3 (used to patch the vendored obs-studio CMake files).
# Everything else (FFmpeg, SIMDe, ...) is fetched automatically by
# obs-studio's own CMake build-dependency system.
set -euo pipefail

OBS_TAG="${OBS_TAG:-32.1.2}"
# Deps version obs-studio's own CMake fetches for this tag, per its
# CMakePresets.json (`dependencies.prebuilt.version`). This is *not*
# independently tunable: it's a fact about OBS_TAG, not a separate knob, and
# the CMake patches below already assert (loudly) that this tag's source
# tree matches what they expect. If you bump OBS_TAG, re-derive this from
# that tag's CMakePresets.json and update it here.
DEPS_VERSION="2025-08-23"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/native/third_party/obs"
WORK="$ROOT/native/third_party/work"
SRC="$WORK/obs-studio"
SRC_TMP="$WORK/.obs-studio.tmp"
CLONE_TAG_MARKER="$WORK/.obs_tag"
BUILD="$WORK/build"
INSTALL="$WORK/install"
STAMP="$OUT/.stamp"

BUILD_ARCH="${CMAKE_OSX_ARCHITECTURES:-$(uname -m)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Stamp encodes everything that changes what ends up in $OUT: the pinned tag,
# the build architecture, and the deps version. Any of those changing must
# invalidate the cache rather than short-circuit onto stale/wrong-arch bits.
STAMP_VALUE="${OBS_TAG} arch=${BUILD_ARCH} deps=${DEPS_VERSION}"

[[ -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" ]] && {
  echo "libobs $OBS_TAG ($BUILD_ARCH) already present in $OUT"
  exit 0
}

# --- Prereqs ---------------------------------------------------------------
command -v cmake >/dev/null 2>&1 || {
  echo "ERROR: cmake not found. Install with: brew install cmake" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  echo "ERROR: git not found." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 not found (used to patch the vendored obs-studio CMake" >&2
  echo "  files). Install with: brew install python3, or install the Xcode" >&2
  echo "  Command Line Tools, which bundle one." >&2
  exit 1
}
if ! xcode-select -p >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: full Xcode.app is required (not just the Command Line Tools)." >&2
  echo "  The pinned obs-studio tree refuses any CMake generator other than" >&2
  echo "  Xcode on macOS. Install Xcode from the App Store, then run:" >&2
  echo "    sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

mkdir -p "$WORK"

# --- 1) Clone obs-studio at the pinned tag, then patch it for a minimal build.
#
# Clone+patch is atomic: it happens entirely in a scratch dir ($SRC_TMP) that
# only gets moved into place ($SRC) once every patch has succeeded. A run
# that dies mid-clone or mid-patch leaves $SRC_TMP behind but never touches
# $SRC, so the next run's guard below sees $SRC missing/stale and redoes the
# whole thing cleanly — no manual `rm -rf` required.
#
# $CLONE_TAG_MARKER records which OBS_TAG $SRC was actually cloned+patched
# at. A warm work dir with a *different* OBS_TAG (or no marker at all, e.g.
# a checkout left by an older version of this script) must not be reused —
# it would silently rebuild the old tag's source and then stamp it as the
# new one.
NEED_CLONE=1
if [[ -d "$SRC" && -f "$CLONE_TAG_MARKER" && "$(cat "$CLONE_TAG_MARKER")" == "$OBS_TAG" ]]; then
  NEED_CLONE=0
fi

if [[ "$NEED_CLONE" == "1" ]]; then
  echo "Cloning obs-studio @ $OBS_TAG ..."
  rm -rf "$SRC" "$SRC_TMP" "$BUILD" "$INSTALL" "$CLONE_TAG_MARKER"
  git clone --depth 1 --branch "$OBS_TAG" https://github.com/obsproject/obs-studio.git "$SRC_TMP"

  # Patch 1/3: replace plugins/CMakeLists.txt with an allow-list.
  #
  # Upstream unconditionally calls check_obs_browser()/check_obs_websocket(),
  # which FATAL_ERROR unless the obs-browser/obs-websocket git submodules are
  # checked out, and it builds every other plugin too — several need SDKs we
  # don't have (AJA, DeckLink, libvlc, fdk-aac). Rewind only ships capture +
  # encode, so replace the file with just the three modules Rewind uses.
  cat > "$SRC_TMP/plugins/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.28...3.30)

# --- Rewind: patched by tools/fetch_libobs.sh ---
# Upstream builds every plugin (and unconditionally requires the obs-browser /
# obs-websocket git submodules to be checked out). Rewind only needs capture +
# encode, so this file is replaced at fetch time with an allow-list of the
# three modules we actually ship: mac-capture, obs-ffmpeg, coreaudio-encoder.

option(ENABLE_PLUGINS "Enable building OBS plugins" ON)

if(NOT ENABLE_PLUGINS)
  set_property(GLOBAL APPEND PROPERTY OBS_FEATURES_DISABLED "Plugin Support")
  return()
endif()

set_property(GLOBAL APPEND PROPERTY OBS_FEATURES_ENABLED "Plugin Support")

add_obs_plugin(coreaudio-encoder PLATFORMS WINDOWS MACOS)
add_obs_plugin(mac-capture PLATFORMS MACOS)
add_obs_plugin(obs-ffmpeg)
EOF

  # Patch 2/3: skip the Qt6 prebuilt download.
  #
  # obs-studio's dependency fetcher (cmake/macos/buildspec.cmake) always
  # fetches prebuilt+qt6+cef regardless of ENABLE_FRONTEND — Qt6 is several
  # hundred MB we never link against since Rewind has no Qt UI.
  python3 - "$SRC_TMP/cmake/macos/buildspec.cmake" << 'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "  set(dependencies_list prebuilt qt6 cef)"
new = (
    "  # Rewind: skip the Qt6 prebuilt fetch (several hundred MB) -- we never\n"
    "  # build ENABLE_FRONTEND, so nothing links against Qt6.\n"
    "  if(ENABLE_FRONTEND)\n"
    "    set(dependencies_list prebuilt qt6 cef)\n"
    "  else()\n"
    "    set(dependencies_list prebuilt cef)\n"
    "  endif()"
)
assert old in text, "buildspec.cmake shape changed upstream; update tools/fetch_libobs.sh"
open(path, "w").write(text.replace(old, new, 1))
PY

  # Patch 3/3: skip libobs-metal.
  #
  # It's Swift, and this tree doesn't wire up enable_language(Swift) for the
  # Xcode generator, so it fails with "CMake can not determine linker
  # language". Rewind is a headless replay-buffer capturer (no on-screen
  # render path), so the OpenGL renderer already enabled is sufficient.
  python3 - "$SRC_TMP/CMakeLists.txt" << 'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "if(OS_MACOS)\n  add_subdirectory(libobs-metal)\nendif()"
new = (
    "# Rewind: libobs-metal is Swift and needs enable_language(Swift), which\n"
    "# this tree doesn't wire up for the Xcode generator. Rewind is headless\n"
    "# (no on-screen render path), so OpenGL alone is sufficient -- skip Metal.\n"
    "option(ENABLE_METAL \"Enable Metal renderer (macOS)\" OFF)\n"
    "if(OS_MACOS AND ENABLE_METAL)\n"
    "  add_subdirectory(libobs-metal)\n"
    "endif()"
)
assert old in text, "root CMakeLists.txt shape changed upstream; update tools/fetch_libobs.sh"
open(path, "w").write(text.replace(old, new, 1))
PY

  mv "$SRC_TMP" "$SRC"
  echo "$OBS_TAG" > "$CLONE_TAG_MARKER"
fi

# --- 2) Configure: libobs + only the modules Rewind needs. No UI, no browser,
#        no scripting, no Metal. Xcode generator is mandatory on macOS for
#        this tree (see prereq check above).
cmake -S "$SRC" -B "$BUILD" -G Xcode \
  -DCMAKE_OSX_ARCHITECTURES="$BUILD_ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DENABLE_FRONTEND=OFF \
  -DENABLE_SCRIPTING=OFF \
  -DENABLE_BROWSER=OFF \
  -DENABLE_METAL=OFF \
  -DENABLE_HEVC=ON \
  -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF \
  -DCMAKE_INSTALL_PREFIX="$INSTALL"

cmake --build "$BUILD" --config RelWithDebInfo -- -jobs "$JOBS"

# libobs is the only target with CMake install() rules in this tree (plugins
# are Xcode-bundle MODULE targets normally copied into the obs-studio.app by
# the frontend build, which we don't build). The rules are EXCLUDE_FROM_ALL
# (component "Development"), so they must be requested explicitly.
cmake --install "$BUILD" --config RelWithDebInfo --component Development

# --- 3) Lay out what Rewind consumes -------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/lib" "$OUT/obs-plugins" "$OUT/data/libobs" "$OUT/data/obs-plugins"

DEPS_DIR="$SRC/.deps/obs-deps-${DEPS_VERSION}-universal"

# include/: flatten framework headers so `obs.h` is directly reachable, plus
# the SIMDe headers obs.h's SSE shims pull in.
rsync -a "$INSTALL/Frameworks/libobs.framework/Headers/" "$OUT/include/"
rsync -a "$DEPS_DIR/include/simde" "$OUT/include/"

# lib/: libobs stays a real .framework (plugins link @rpath/libobs.framework/...,
# flattening it would break their load commands -- Task 9/10 decide the final
# app-bundle rpath layout), libobs-opengl, and the FFmpeg/x264/mbedTLS/rist/srt
# dylibs obs-ffmpeg links against transitively.
rsync -a "$INSTALL/Frameworks/libobs.framework" "$OUT/lib/"
cp "$BUILD/libobs-opengl/RelWithDebInfo/libobs-opengl.dylib" "$OUT/lib/"
rsync -a \
  "$DEPS_DIR"/lib/libavcodec* "$DEPS_DIR"/lib/libavdevice* "$DEPS_DIR"/lib/libavfilter* \
  "$DEPS_DIR"/lib/libavformat* "$DEPS_DIR"/lib/libavutil* "$DEPS_DIR"/lib/libswresample* \
  "$DEPS_DIR"/lib/libswscale* "$DEPS_DIR"/lib/librist* "$DEPS_DIR"/lib/libsrt* \
  "$DEPS_DIR"/lib/libx264* "$DEPS_DIR"/lib/libmbedcrypto* "$DEPS_DIR"/lib/libmbedtls* \
  "$DEPS_DIR"/lib/libmbedx509* \
  "$OUT/lib/"

# obs-plugins/: the three plugin bundles (built as .plugin bundles, not flat .so)
cp -R "$BUILD/plugins/mac-capture/RelWithDebInfo/mac-capture.plugin" "$OUT/obs-plugins/"
cp -R "$BUILD/plugins/obs-ffmpeg/RelWithDebInfo/obs-ffmpeg.plugin" "$OUT/obs-plugins/"
cp -R "$BUILD/plugins/coreaudio-encoder/RelWithDebInfo/coreaudio-encoder.plugin" "$OUT/obs-plugins/"

# data/: libobs core (effects, locale) + per-plugin data (locale)
rsync -a "$SRC/libobs/data/" "$OUT/data/libobs/"
rsync -a "$SRC/plugins/mac-capture/data/" "$OUT/data/obs-plugins/mac-capture/"
rsync -a "$SRC/plugins/obs-ffmpeg/data/" "$OUT/data/obs-plugins/obs-ffmpeg/"
rsync -a "$SRC/plugins/coreaudio-encoder/data/" "$OUT/data/obs-plugins/coreaudio-encoder/"

echo "$STAMP_VALUE" > "$STAMP"
echo "libobs $OBS_TAG ($BUILD_ARCH) ready in $OUT"
