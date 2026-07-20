#!/usr/bin/env bash
# Build a minimal libobs + capture/encode plugins for Rewind on Linux,
# pinned + cached. Result lands in native/third_party/obs/ (git-ignored).
# Idempotent: skips work when the stamp file matches OBS_TAG + recipe
# version.
#
# Like macOS (tools/fetch_libobs.sh), this BUILDS libobs from source via
# CMake — unlike Windows (tools/fetch_libobs_windows.ps1), which repackages
# an official prebuilt runtime zip, obs-studio publishes no equivalent
# "Linux portable build" artifact suitable for that shortcut (distros are
# expected to build from source against their own system libraries, which
# is exactly what this script does too, just against a narrow plugin
# allow-list). Ninja (not the Xcode generator macOS's script requires) is
# used as the CMake generator, matching how obs-studio's own CI configures
# `ubuntu-ci` (see .github/scripts/build-ubuntu / CMakePresets.json's
# "ubuntu" preset at the pinned tag).
#
# Pinned to the SAME libobs tag as macOS/Windows (see tools/fetch_libobs.sh's
# OBS_TAG) so behavior/id assumptions stay comparable across platforms. If
# you bump one, bump all three and re-verify source/encoder ids (see
# native/shim/README.md's Linux section) against the new tag's
# plugins/linux-capture, plugins/linux-pipewire, plugins/linux-pulseaudio,
# plugins/obs-ffmpeg, plugins/obs-nvenc, plugins/obs-x264 sources — ids and
# settings keys are NOT guaranteed stable across libobs releases.
#
# Requires (Ubuntu/Debian package names; see the pkg-config checks below for
# the exact module names this script verifies before configuring):
#   build-essential cmake ninja-build git python3 pkg-config
#   extra-cmake-modules  (KDE's ECM: obs-studio's cmake/linux/defaults.cmake
#                         does find_package(ECM) — without it CMake fails at
#                         configure with "Could not find a package
#                         configuration file provided by ECM")
#   libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev
#   libavutil-dev libswresample-dev libswscale-dev
#   zlib1g-dev uthash-dev libjansson-dev libsimde-dev
#   libx11-dev libx11-xcb-dev libxcb1-dev libxcb-shm0-dev libxcb-randr0-dev
#   libxcb-xinerama0-dev libxcb-composite0-dev libxcb-xfixes0-dev
#   libxcomposite-dev libdrm-dev
#   libwayland-dev libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev
#   libpipewire-0.3-dev libglib2.0-dev
#   libpulse-dev
#   libx264-dev
#   libva-dev libpci-dev
#   libffmpeg-nvenc-dev
# On Ubuntu 22.04/24.04 (the ubuntu-latest CI image at the time this script
# was written):
#   sudo apt-get install -y --no-install-recommends \
#     build-essential cmake ninja-build git python3 pkg-config \
#     extra-cmake-modules \
#     libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
#     libavutil-dev libswresample-dev libswscale-dev \
#     zlib1g-dev uthash-dev libjansson-dev libsimde-dev \
#     libx11-dev libx11-xcb-dev libxcb1-dev libxcb-shm0-dev \
#     libxcb-randr0-dev libxcb-xinerama0-dev libxcb-composite0-dev \
#     libxcb-xfixes0-dev libxcomposite-dev libdrm-dev \
#     libwayland-dev libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev \
#     libpipewire-0.3-dev libglib2.0-dev \
#     libpulse-dev libx264-dev libva-dev libpci-dev libffmpeg-nvenc-dev
# This script does NOT run apt-get itself (same policy as fetch_libobs.sh's
# "brew install cmake" message, not an auto-brew-install) — CI installs
# these explicitly as its own step (see .github/workflows/ci.yml's
# build-linux-libobs job) so the exact package list stays visible/auditable
# there rather than hidden inside this script.
set -euo pipefail

OBS_TAG="${OBS_TAG:-32.1.2}"

# Bumped whenever the source patches or the assembled-output recipe below
# change (e.g. adding/removing a plugin) — same purpose as fetch_libobs.sh's
# RECIPE_VERSION.
#   1: initial cut — linux-capture (X11), linux-pipewire (Wayland portal),
#      linux-pulseaudio, obs-ffmpeg (VAAPI + ffmpeg_aac), obs-nvenc, obs-x264.
#   2: + obs-filters (compressor/limiter/noise suppression for the mic
#      chain; SpeexDSP disabled — the vendored internal RNNoise needs no
#      system dep and is the suppression method Rewind uses).
RECIPE_VERSION="2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/native/third_party/obs"
WORK="$ROOT/native/third_party/work-linux"
SRC="$WORK/obs-studio"
SRC_TMP="$WORK/.obs-studio.tmp"
CLONE_TAG_MARKER="$WORK/.obs_tag"
BUILD="$WORK/build"
STAMP="$OUT/.stamp"

BUILD_ARCH="$(uname -m)"
JOBS="${JOBS:-$(nproc)}"

STAMP_VALUE="${OBS_TAG} arch=${BUILD_ARCH} recipe=${RECIPE_VERSION}"

[[ -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" ]] && {
  echo "libobs $OBS_TAG ($BUILD_ARCH) already present in $OUT"
  exit 0
}

# --- Prereqs -----------------------------------------------------------
for tool in cmake ninja git python3 pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool not found. See this script's header comment for the" >&2
    echo "  full apt-get install line." >&2
    exit 1
  }
done

# KDE's Extra CMake Modules isn't a binary, so the loop above can't catch it —
# but obs-studio's cmake/linux/defaults.cmake does find_package(ECM), and
# without it configure dies ~2 minutes in with "Could not find a package
# configuration file provided by ECM", which names a CMake package rather than
# the apt package you actually need. Fail fast with the real answer instead.
# NB: test each candidate separately — `ls a b` exits non-zero when ANY arg is
# missing, so a single ls over several paths reports "not found" even when ECM
# is installed (which is exactly how this check failed its first CI run).
ecm_found=0
for ecm_cand in /usr/share/ECM/cmake/ECMConfig.cmake \
                /usr/share/cmake/ECM/ECMConfig.cmake \
                /usr/lib/*/cmake/ECM/ECMConfig.cmake; do
  if [ -e "$ecm_cand" ]; then
    ecm_found=1
    break
  fi
done
if [ "$ecm_found" -eq 0 ]; then
  echo "ERROR: KDE Extra CMake Modules (ECM) not found — obs-studio's" >&2
  echo "  cmake/linux/defaults.cmake requires it." >&2
  echo "  Install it:  sudo apt-get install -y extra-cmake-modules" >&2
  exit 1
fi

# pkg-config module presence check for the handful of libraries that would
# otherwise fail deep inside CMake configure with a much less obvious error
# (a REQUIRED find_package() failure names a CMake package name, not the
# apt package that provides it). Not exhaustive — just the ones most likely
# to be missing on a bare CI image, so a missing dependency fails fast with
# the install line right there instead of a multi-minute CMake configure
# ending in a cryptic message.
declare -A PKGCONFIG_MODULES=(
  [libavformat]="ffmpeg-dev (libavformat-dev)"
  [libavcodec]="ffmpeg-dev (libavcodec-dev)"
  [x11]="libx11-dev"
  [x11-xcb]="libx11-xcb-dev"
  [xcb]="libxcb1-dev"
  [xcb-randr]="libxcb-randr0-dev"
  [libpipewire-0.3]="libpipewire-0.3-dev"
  [glib-2.0]="libglib2.0-dev"
  [libpulse]="libpulse-dev"
  [x264]="libx264-dev"
  [libva]="libva-dev"
  [libdrm]="libdrm-dev"
  [ffnvcodec]="libffmpeg-nvenc-dev"
)
missing=()
for mod in "${!PKGCONFIG_MODULES[@]}"; do
  pkg-config --exists "$mod" 2>/dev/null || missing+=("$mod (${PKGCONFIG_MODULES[$mod]})")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required pkg-config modules:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  echo "  See this script's header comment for the full apt-get install line." >&2
  exit 1
fi

mkdir -p "$WORK"

# --- 1) Clone obs-studio at the pinned tag, then patch it for a minimal
#        build. Same atomic clone-into-scratch-dir-then-move approach as
#        fetch_libobs.sh (see that script's comment for why).
CLONE_MARKER_VALUE="${OBS_TAG} recipe=${RECIPE_VERSION}"
NEED_CLONE=1
if [[ -d "$SRC" && -f "$CLONE_TAG_MARKER" && "$(cat "$CLONE_TAG_MARKER")" == "$CLONE_MARKER_VALUE" ]]; then
  NEED_CLONE=0
fi

if [[ "$NEED_CLONE" == "1" ]]; then
  echo "Cloning obs-studio @ $OBS_TAG ..."
  rm -rf "$SRC" "$SRC_TMP" "$BUILD" "$CLONE_TAG_MARKER"
  git clone --depth 1 --branch "$OBS_TAG" https://github.com/obsproject/obs-studio.git "$SRC_TMP"

  # Patch 1/1: replace plugins/CMakeLists.txt with an allow-list.
  #
  # Upstream unconditionally calls check_obs_browser()/check_obs_websocket()
  # (FATAL_ERROR unless the obs-browser/obs-websocket git submodules are
  # checked out) and builds every other plugin too, several needing SDKs we
  # don't have (AJA, DeckLink, VLC, fdk-aac, VST). Rewind only ships
  # capture + encode: linux-capture (X11 xshm/xcomposite), linux-pipewire
  # (Wayland portal capture), linux-pulseaudio (desktop/mic audio),
  # obs-ffmpeg (VAAPI H.264 + ffmpeg_aac + the mux helper),
  # obs-nvenc (NVIDIA H.264), obs-x264 (software H.264 fallback).
  cat > "$SRC_TMP/plugins/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.28...3.30)

# --- Rewind: patched by tools/fetch_libobs_linux.sh ---
# Upstream builds every plugin (and unconditionally requires the obs-browser
# / obs-websocket git submodules to be checked out). Rewind only needs
# capture + encode, so this file is replaced at fetch time with an
# allow-list of the modules we actually ship.

option(ENABLE_PLUGINS "Enable building OBS plugins" ON)

if(NOT ENABLE_PLUGINS)
  set_property(GLOBAL APPEND PROPERTY OBS_FEATURES_DISABLED "Plugin Support")
  return()
endif()

set_property(GLOBAL APPEND PROPERTY OBS_FEATURES_ENABLED "Plugin Support")

add_obs_plugin(linux-capture PLATFORMS LINUX)
add_obs_plugin(linux-pipewire PLATFORMS LINUX)
add_obs_plugin(linux-pulseaudio PLATFORMS LINUX)
add_obs_plugin(obs-ffmpeg)
add_obs_plugin(obs-nvenc)
add_obs_plugin(obs-x264)
add_obs_plugin(obs-filters)
EOF

  mv "$SRC_TMP" "$SRC"
  echo "$CLONE_MARKER_VALUE" > "$CLONE_TAG_MARKER"
fi

# --- 2) Configure + build: libobs + only the modules Rewind needs. No UI,
#        no browser, no scripting, no RIST/SRT mpegts output (not needed for
#        a local replay-buffer/recording-only app — see obs-ffmpeg's own
#        cmake/dependencies.cmake at the pinned tag: disabling this avoids
#        needing librist-dev/libsrt-openssl-dev at all).
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DENABLE_FRONTEND=OFF \
  -DENABLE_SCRIPTING=OFF \
  -DENABLE_BROWSER=OFF \
  -DENABLE_WEBRTC=OFF \
  -DENABLE_VLC=OFF \
  -DENABLE_AJA=OFF \
  -DENABLE_NEW_MPEGTS_OUTPUT=OFF \
  -DENABLE_WAYLAND=ON \
  -DENABLE_PULSEAUDIO=ON \
  -DENABLE_NVENC=ON \
  -DENABLE_HEVC=ON \
  -DENABLE_SPEEXDSP=OFF \
  -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF

cmake --build "$BUILD" --config RelWithDebInfo --parallel "$JOBS"

# --- 3) Lay out what Rewind consumes ---------------------------------
rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/lib" "$OUT/obs-plugins" "$OUT/data/libobs" "$OUT/data/obs-plugins"

# include/: every libobs/**/*.h, flattened so obs.h sits directly under
# include/ — same shape as the macOS/Windows SDKs' include/ (matches what
# rewind_obs_internal.h's `#include <obs.h>` / `#include <util/platform.h>`
# expect: obs.h at the root, util/ as a subdirectory).
find "$SRC/libobs" -name '*.h' | while read -r hdr; do
  rel="${hdr#"$SRC"/libobs/}"
  mkdir -p "$OUT/include/$(dirname "$rel")"
  cp "$hdr" "$OUT/include/$rel"
done
# obsconfig.h is normally CMake-generated at configure time from
# libobs/obsconfig.h.in into the BUILD tree (not the source tree the loop
# above walks) — copy the real generated one so any conditional it guards
# matches what libobs was actually built with (unlike the Windows script,
# which synthesizes a placeholder since it never runs CMake at all).
find "$BUILD" -name 'obsconfig.h' -exec cp {} "$OUT/include/obsconfig.h" \;

# lib/: libobs.so + libobs-opengl.so, each together with their SOVERSION
# file and the bare-name symlink CMake creates (rsync -a preserves local
# symlinks, so all three land in lib/ together and the bare name always
# resolves — see rw_plat_find_graphics_module_path()'s doc comment in
# rewind_obs_linux.c for why the bare "libobs-opengl.so" name matters).
find "$BUILD" -maxdepth 2 -name 'libobs.so*' -exec cp -P {} "$OUT/lib/" \;
find "$BUILD" -name 'libobs-opengl.so*' -exec cp -P {} "$OUT/lib/" \;
if [[ ! -e "$OUT/lib/libobs.so" || ! -e "$OUT/lib/libobs-opengl.so" ]]; then
  echo "ERROR: libobs.so / libobs-opengl.so (or their bare-name symlink)" >&2
  echo "  not found under $BUILD after build — Ninja output layout may" >&2
  echo "  have changed; inspect $BUILD manually." >&2
  exit 1
fi

# obs-plugins/: the plugin .so files (flat, PREFIX "" per each plugin's own
# CMakeLists.txt — see rw_plat_setup_module_paths()'s doc comment in
# rewind_obs_linux.c).
for plugin in linux-capture linux-pipewire linux-pulseaudio obs-ffmpeg obs-nvenc obs-x264 obs-filters; do
  found="$(find "$BUILD" -maxdepth 3 -name "${plugin}.so" | head -n1)"
  if [[ -z "$found" ]]; then
    echo "ERROR: required plugin missing from build: ${plugin}.so (plugin" >&2
    echo "  allow-list patch or CMake configure may have silently skipped it)" >&2
    exit 1
  fi
  cp "$found" "$OUT/obs-plugins/${plugin}.so"
done

# bin/: the obs-ffmpeg-mux helper. obs-ffmpeg's muxer/replay-buffer SPAWNS
# this standalone executable to write files, resolving it next to the main
# app executable (os_get_executable_path_ptr) — see
# rw_plat_mux_helper_present() in rewind_obs_linux.c. No bundler script
# exists yet to place it next to rewind's own binary (packaging was out of
# scope for this task); kept here so a future one has an obvious source.
mkdir -p "$OUT/bin"
found_mux="$(find "$BUILD" -maxdepth 3 -name 'obs-ffmpeg-mux' -type f | head -n1)"
if [[ -z "$found_mux" ]]; then
  echo "ERROR: obs-ffmpeg-mux helper not found under $BUILD after build." >&2
  exit 1
fi
cp "$found_mux" "$OUT/bin/"

# data/: libobs core (effects, locale) + per-plugin data (locale)
cp -a "$SRC/libobs/data/." "$OUT/data/libobs/"
for plugin in linux-capture linux-pipewire linux-pulseaudio obs-ffmpeg obs-nvenc obs-x264 obs-filters; do
  if [[ -d "$SRC/plugins/$plugin/data" ]]; then
    mkdir -p "$OUT/data/obs-plugins/$plugin"
    cp -a "$SRC/plugins/$plugin/data/." "$OUT/data/obs-plugins/$plugin/"
  fi
done

echo "$STAMP_VALUE" > "$STAMP"
echo "libobs $OBS_TAG ($BUILD_ARCH) ready in $OUT"
