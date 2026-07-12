# Rewind native shim (`rewind_obs`)

A tiny C shim over **libobs** — the only native code in Rewind. It exposes a
handful of C functions (see `rewind_obs.h`) that the Dart side calls via
`dart:ffi`. All libobs complexity is hidden here.

## Current state

`rewind_obs.c` has two implementations, selected at compile time:

- **`REWIND_USE_LIBOBS` defined** — the real libobs-backed implementation
  (macOS only so far). Requires the fetched SDK at
  `native/third_party/obs/` (see `tools/fetch_libobs.sh`, gitignored,
  pinned to libobs **32.1.2**).
- **`REWIND_USE_LIBOBS` undefined** — a self-contained **stub** so the
  Flutter app links and runs before libobs is wired in, or on platforms
  without a built SDK yet. `rewind_save_clip` returns a synthesized path
  so the Dart pipeline can be exercised end-to-end in "dev mode", but does
  not actually write a file.

## Real mode: how it works (macOS)

`rewind_obs_init` does, in order:

1. **Locate the SDK.** `find_obs_sdk_dir()` tries, in order: a
   `REWIND_OBS_SDK_DIR` compile-time define (not currently set by any
   build step — reserved for Task 10/packaging to point at a bundled
   `Contents/Resources/obs`); `<shim dylib dir>/../Resources/obs` (the
   eventual packaged `.app` layout); walking up from the shim's own
   directory looking for `native/third_party/obs` (works for
   `flutter run`/`flutter build macos` dev builds, whose build products
   stay nested under the repo root). The shim's own directory is resolved
   via `dladdr` on one of its exported symbols — it does not assume any
   fixed install location.
2. **`obs_startup` + `obs_reset_video`/`obs_reset_audio`.** Base/output
   resolution comes from `CGDisplayPixelsWide/High(CGMainDisplayID())`
   (CoreGraphics), not a hardcoded value; 1920x1080 is only a last-resort
   fallback if the query returns 0. `graphics_module` is passed as an
   **absolute path** to `<sdk>/lib/libobs-opengl.dylib`, not the bare name
   `"libobs-opengl"` — see "Deviations from a naive port" below for why.
3. **`obs_add_module_path`** for the `<sdk>/obs-plugins` (`.plugin`
   bundles) and `<sdk>/data/obs-plugins` (locale data) trees, then
   `obs_load_all_modules()` + `obs_post_load_modules()`.
4. **Capture source**: `screen_capture` (ScreenCaptureKit, from
   `mac-capture`), main display selected via a computed `display_uuid`
   (leaving it unset resolves to display id 0 — no display).
5. **Encoders**: VideoToolbox H.264 (`com.apple.videotoolbox.videoencoder.ave.avc`,
   from `mac-videotoolbox`) + CoreAudio AAC (`CoreAudio_AAC`, from
   `coreaudio-encoder`).
6. **Replay buffer output** (`replay_buffer`, from `obs-ffmpeg`), settings
   `directory`/`format`/`extension`/`max_time_sec`/`max_size_mb`.

`rewind_save_clip` calls the `save` proc on the output's proc handler, then
polls `get_last_replay` (up to 5s at 50ms intervals) for the written path —
there's no synchronous "save and return the path" call in the API, and the
`saved()` signal would need signal-handler plumbing this shim doesn't have.

## `mac-videotoolbox` (status: re-fetch landed, not yet runtime-verified)

The VideoToolbox H.264 encoder is a separate module
(`plugins/mac-videotoolbox` in the obs-studio tree) from
`mac-capture`/`obs-ffmpeg`/`coreaudio-encoder`. Earlier fetches of
`native/third_party/obs/` didn't include it (nor a software fallback —
`obs-ffmpeg` itself only registers NVENC/VAAPI (Linux) and AMF (Windows)
encoders, none usable on macOS), which meant `rewind_obs_init` would run
all the way through capture-source creation and then fail at
`obs_video_encoder_create("com.apple.videotoolbox.videoencoder.ave.avc", ...)`
returning `NULL`.

`tools/fetch_libobs.sh` has since been re-run with `mac-videotoolbox`
added to its plugin allow-list:
`native/third_party/obs/obs-plugins/mac-videotoolbox.plugin` and
`native/third_party/obs/data/obs-plugins/mac-videotoolbox/` both exist
now, with the same `.plugin` bundle / flat data-dir layout as the other
three modules — `setup_module_paths()`'s `%module%.plugin/Contents/MacOS`
+ `data/obs-plugins/%module%` templates need no shim change to pick it
up. This hasn't been confirmed with an actual run of `rewind_obs_init`
yet (this task's checks are compile/link-only) — worth a real smoke test
once Task 10's linkage/bundling exists.

## Deviations from a naive port of the reference implementation

Verified against the real headers in `native/third_party/obs/include` and
the vendored source tree in `native/third_party/work/obs-studio/` at the
pinned tag (32.1.2), not assumed from memory:

- **`graphics_module` must be an absolute path to `libobs-opengl.dylib`,
  not the bare string `"libobs-opengl"`.** `os_dlopen()` (`util/platform-nix.c`,
  used on macOS too) appends `.so` to any name that doesn't already
  contain `.framework`/`.plugin`/`.dylib`/`.so` — so a bare
  `"libobs-opengl"` becomes a `dlopen("libobs-opengl.so")` call, which
  doesn't exist. Even with the right extension, a bare filename (no `/`)
  is resolved via dyld's environment/fallback search paths, not our
  `lib/` directory — obs-studio's own frontend gets this filename from
  `TARGET_SONAME_FILE_NAME` at CMake configure time and relies on the
  built app's own rpath/search setup, neither of which exists here. Using
  a full absolute path sidesteps all of that.
- **`obs_add_module_path` needs `%module%.plugin/Contents/MacOS` in the
  bin template on macOS**, not a flat plugins directory. Traced through
  `libobs/obs-module.c`'s `find_modules_in_path`/`parse_binary_from_directory`:
  with no `%module%` in the bin path, it globs for files (not
  directories) ending in the module extension directly inside `bin` —
  which never matches `.plugin` *bundles*. The `%module%` placeholder
  makes it scan `<obs-plugins>/*` as directories, strip `.plugin`, and
  build `<obs-plugins>/<name>.plugin/Contents/MacOS/<name>` — which is
  what the fetched `.plugin` bundles actually contain. The **data**
  template does *not* need the same `.plugin/Contents/Resources` nesting
  — it's substituted independently via `make_data_directory`, so a flat
  `<sdk>/data/obs-plugins/%module%` matches the flat layout
  `tools/fetch_libobs.sh` actually produces.
- **No `obs_add_data_path` call for libobs's own core data (effects).**
  `find_libobs_data_file()` (`libobs/obs-cocoa.m`) on macOS *always*
  resolves against `[NSBundle bundleWithIdentifier:@"com.obsproject.libobs"]`'s
  own `Resources/` — and always returns non-NULL, so the
  `obs_add_data_path`-populated fallback path list in `obs_find_data_file`
  is never reached on this platform. Confirmed the fetched
  `lib/libobs.framework/Versions/A/Resources/` already contains
  `default.effect` etc. (a normal consequence of `libobs` being built as
  a real `FRAMEWORK TRUE` CMake target) — no extra wiring needed. The
  deprecated `obs_add_data_path` API is intentionally unused.
- **Capture source needs an explicit `display_uuid`.** Leaving it unset
  (the property's own default) resolves to `CGDirectDisplayID 0` in
  `get_display_migrate_settings()` (`plugins/mac-capture/window-utils.m`)
  — not the main display. The shim computes it the same way the property
  UI would: `CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())` →
  `CFUUIDCreateString`.
- **Source id `"screen_capture"` was correct as written in the brief** —
  double-checked because there's also a legacy `"display_capture"` source
  in the same plugin; `"screen_capture"` (ScreenCaptureKit-backed) is
  registered whenever `is_screen_capture_available()` is true, which it
  is on the macOS versions Rewind targets (`plugins/mac-capture/plugin-main.c`).
- Everything else (encoder ids, `obs_video_encoder_create`/
  `obs_audio_encoder_create` signatures, `replay_buffer`'s
  `directory`/`format`/`extension`/`max_time_sec`/`max_size_mb` settings
  keys, the `save`/`get_last_replay` proc names, `os_sleep_ms`) matched
  the brief's reference code as written against the 32.1.2 headers and
  `plugins/obs-ffmpeg/obs-ffmpeg-mux.c` source.

## Wiring up real libobs

1. `tools/fetch_libobs.sh` builds/lays out the SDK at
   `native/third_party/obs/` (gitignored). See the gap above —
   `mac-videotoolbox` needs adding to its plugin allow-list before a
   fetch produces a fully working encoder set.
2. Build the shared library:

   **macOS**
   ```bash
   clang -shared -fPIC native/shim/rewind_obs.c -o librewind_obs.dylib \
     -DREWIND_USE_LIBOBS -Inative/third_party/obs/include \
     -Fnative/third_party/obs/lib -framework libobs \
     -framework ApplicationServices
   ```
   (verified: syntax-checks clean and links successfully as of this task;
   the resulting dylib's only unresolved load command is
   `@rpath/libobs.framework/Versions/A/libobs`, which Task 10's app
   bundling needs to satisfy via an `@rpath`/`Frameworks/` setup.)

   **Windows (MSVC)** — not implemented yet.
   ```bat
   cl /LD rewind_obs.c /DREWIND_USE_LIBOBS /I <obs>\libobs obs.lib
   ```

3. Place the resulting library where the app can `DynamicLibrary.open` it
   (next to the executable / inside the `.app` bundle). Ship libobs'
   runtime `data/` and `obs-plugins/` alongside — see ARCHITECTURE.md →
   Packaging.

## Licensing

Linking libobs makes the whole app GPLv3. Keep this shim GPLv3 and free of
GPL-incompatible dependencies.
