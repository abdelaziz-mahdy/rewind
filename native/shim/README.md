# Rewind native shim (`rewind_obs`)

A tiny C shim over **libobs** — the only native code in Rewind. It exposes a
handful of C functions (see `rewind_obs.h`) that the Dart side calls via
`dart:ffi`. All libobs complexity is hidden here.

## File layout

- `rewind_obs.h` — the public API. The ENTIRE surface Dart sees.
- `rewind_obs.c` — shared layer: the public API's dispatch logic, shared
  mutable state, shared helpers, and the whole no-libobs stub. Compiles on
  every platform, in both modes.
- `rewind_obs_internal.h` — internal (not Dart-visible) seam between the
  shared layer and the per-platform backends: `extern` declarations for the
  shared state/helpers, plus the `rw_plat_*` function interface every
  backend implements.
- `rewind_obs_macos.c` / `rewind_obs_windows.c` — the two libobs backends,
  each implementing every `rw_plat_*` function for its platform. Compiled
  only when `REWIND_USE_LIBOBS` is defined AND the matching platform macro
  is set (see `hook/build.dart`); each file's body is also self-guarded the
  same way, so an accidental compile elsewhere is a harmless empty
  translation unit. Adding a third backend (e.g. Linux) means writing a
  `rewind_obs_linux.c` implementing the same interface — no changes needed
  to `rewind_obs.c`.

## Current state

The real implementation is split by platform (see "File layout" above),
selected at compile time by two independent switches:

- **`REWIND_USE_LIBOBS` defined** — the real libobs-backed implementation:
  `rewind_obs_macos.c` compiles on macOS, `rewind_obs_windows.c` on
  Windows. Requires the fetched SDK at `native/third_party/obs/` (see
  `tools/fetch_libobs.sh` on macOS / `tools/fetch_libobs_windows.ps1` on
  Windows, both gitignored, pinned to libobs **32.1.2**). The macOS path is
  real-world exercised (see the macOS section below); the Windows path is
  implemented and compiles in CI against the real SDK but is **not yet
  validated on real Windows hardware** — see the Windows section below for
  exactly what's verified-by-source-reading vs. still an assumption.
- **`REWIND_USE_LIBOBS` undefined** — a self-contained **stub**, entirely
  inside `rewind_obs.c` (works on every platform) so the Flutter app links
  and runs before libobs is wired in, or on platforms without a built SDK
  yet. `rewind_save_clip` returns a synthesized path so the Dart pipeline
  can be exercised end-to-end in "dev mode", but does not actually write a
  file.

## Real mode: how it works (macOS)

`rewind_obs_init` does, in order:

1. **Locate the SDK.** `find_obs_sdk_dir()` tries, in order: a
   `REWIND_OBS_SDK_DIR` compile-time define (not currently set by any
   build step); `<shim dylib dir>/../Resources/obs` (packaged `.app`
   layout if the shim ever ships as a flat dylib directly in
   `Contents/Frameworks/`); `<shim dylib dir>/../../../../Resources/obs`
   (the packaged `.app` layout for how Flutter's macOS toolchain actually
   wraps the compiled shim today — as a *nested* framework bundle,
   `Contents/Frameworks/rewind_obs.framework/Versions/A/rewind_obs`, four
   directory levels below `Contents`, not one — discovered during Task
   10's real bundling run, see `.superpowers/sdd/task-10-report.md`);
   walking up from the shim's own directory looking for
   `native/third_party/obs` (works for `flutter run`/`flutter build
   macos` dev builds, whose build products stay nested under the repo
   root). The shim's own directory is resolved via `dladdr` on one of its
   exported symbols — it does not assume any fixed install location.
2. **`obs_startup` + `obs_reset_video`/`obs_reset_audio`.** Base/output
   resolution comes from `CGDisplayPixelsWide/High(CGMainDisplayID())`
   (CoreGraphics), not a hardcoded value; 1920x1080 is only a last-resort
   fallback if the query returns 0. `graphics_module` is passed as an
   **absolute path** to `libobs-opengl.dylib`, not the bare name
   `"libobs-opengl"` — see "Deviations from a naive port" below for why.
   That absolute path is resolved by `find_graphics_module_path()`,
   *separately* from the SDK dir `find_obs_sdk_dir()` resolved above:
   in the packaged `.app` layout, `tools/bundle_obs_macos.sh` places the
   whole `lib/` closure (`libobs.framework`, `libobs-opengl.dylib`, the
   FFmpeg/x264/mbedTLS dylibs) directly in `Contents/Frameworks/`, and
   only `obs-plugins/`+`data/` under `Contents/Resources/obs` — so there
   is **no `lib/` under the resolved SDK dir** in that layout, only in
   the dev-tree one. `find_graphics_module_path()` tries, in order:
   `<sdk dir>/lib/libobs-opengl.dylib` (dev-tree layout);
   `<shim dir>/../../../libobs-opengl.dylib` (packaged layout, the
   nested-framework shim placement Flutter's macOS toolchain actually
   uses — mirrors `find_obs_sdk_dir()`'s own nested candidate, minus the
   extra `Resources/obs` hop since vendored dylibs sit directly in
   `Frameworks/`); `<shim dir>/libobs-opengl.dylib` (packaged layout,
   flat-dylib shim placement, kept as insurance against a future
   toolchain change). If none exist, the error names every path tried.
   Found during a real packaged-app run — see
   `.superpowers/sdd/task-10-report.md` and `task-9-report.md`'s fix-round
   notes.
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
- **Display picking (`rewind_list_displays`/`rewind_set_capture_display`).**
  `"display_uuid"` (a string) is confirmed as `screen_capture`'s settings
  key for the target display (`plugins/mac-capture/mac-sck-video-capture.m`,
  `sck_video_capture_defaults`/`sck_video_capture_update`). Switching
  displays does **not** require recreating the source: `.update =
  sck_video_capture_update` re-reads `display_uuid` via
  `get_display_migrate_settings()` and tears down/reinitialises its own
  `SCStream` internally, so a plain `obs_source_update(g_capture, settings)`
  on the existing source is enough — `rewind_set_capture_display()` does
  exactly that when a capture source already exists, and just remembers the
  preference (in a static, applied at the next `rewind_obs_init`)
  otherwise. `rewind_list_displays()` enumerates via
  `CGGetActiveDisplayList` + `CGDisplayCreateUUIDFromDisplayID` +
  `CGDisplayPixelsWide/High` + `CGDisplayIsMain` — all CoreGraphics, already
  reachable through the `ApplicationServices` umbrella header/framework this
  file already includes/links; no new build flag needed.
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
- **Application picking (`rewind_list_capturable_apps`/
  `rewind_set_capture_app`).** `screen_capture`'s settings keys, confirmed
  in `plugins/mac-capture/mac-sck-video-capture.m`
  (`sck_video_capture_defaults`/`sck_video_capture_update`/
  `init_screen_stream`'s `ScreenCaptureApplicationStream` case): `"type"`
  (int, `0`=display / `1`=window / `2`=application —
  `ScreenCaptureDisplayStream`/`ScreenCaptureWindowStream`/
  `ScreenCaptureApplicationStream`) and `"application"` (string, a bundle
  id, matched against `SCRunningApplication.bundleIdentifier` in
  `shareable_content.applications`). Only display (`0`) and application
  (`2`) are wired up — window (`1`, keyed by `"window"`, a `CGWindowID` —
  see the same file) is out of scope for this task, deliberately not
  implemented.
  - **Application capture still needs `"display_uuid"`.** `init_screen_stream`'s
    `ScreenCaptureApplicationStream` case calls `get_target_display()`
    (backed by `sc->display`, set every `.update` from
    `get_display_migrate_settings(settings)` — same helper the display-only
    path uses, `window-utils.m`) — an app target with no display resolves
    to `CGDirectDisplayID 0` and the stream silently fails to start (logged,
    not fatal — `MACCAP_ERR("init_screen_stream: Invalid target display
    ID:  %u\n", ...)`, source stays valid with `sc->disp = NULL`, i.e. a
    blank feed). `rewind_obs_init()` and `rewind_set_capture_app()` both
    always set `display_uuid` (from `g_display_uuid`/`main_display_uuid()`)
    alongside `type`/`application`, exactly like the display-only path —
    the app target just also carries a display target under it, used if
    the app target is ever cleared.
  - **Switching types re-inits in place, same as display switching.**
    `sck_video_capture_update`'s early-return fast path only applies when
    `"type"` doesn't change; any type change (including the boundary this
    task cares about — display ⟷ application) falls through to
    `destroy_screen_stream()` + `init_screen_stream()`, run against the
    *already-running* `obs_source_t`. So `rewind_set_capture_app()` reuses
    the same update-not-recreate approach as `rewind_set_capture_display()`
    — `obs_source_update(g_capture, settings)` is enough, no source
    recreation.
  - **`obs_source_update()` merges, it doesn't replace.** Confirmed against
    `libobs/obs-source.c`: `obs_source_update()` calls
    `obs_data_apply(source->context.settings, settings)` (a merge — only
    the keys present in `settings` are overwritten) *before* passing the
    full persisted `source->context.settings` to `.update`. This is why
    `rewind_set_capture_app()` doesn't need to resend `display_uuid` when
    switching *away* from an app back to plain display capture (just
    `"type": 0`) — whatever `display_uuid` the source already has (from
    init or a prior `rewind_set_capture_display`) survives the merge and
    is what `.update` reads.
  - **App enumeration is pure C, not a port of `mac-sck-common.m`'s
    `build_application_list()`** (which walks `SCShareableContent` via
    ObjC/`SCShareableContent.applications`, async, needs a semaphore-gated
    round trip). Instead: `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly
    | kCGWindowListExcludeDesktopElements, kCGNullWindowID)` (CoreGraphics)
    gives every on-screen window's `kCGWindowOwnerPID`; `proc_pidpath()`
    (`<libproc.h>`, part of libSystem, no extra framework) resolves that
    pid to its executable's absolute path; walking the path up to the
    nearest ancestor directory ending in `.app` gives the bundle root,
    which `CFBundleCreate()`/`CFBundleGetIdentifier()` (CoreFoundation)
    reads for the bundle id — the same identifier
    `ScreenCaptureApplicationStream`'s match loop compares against
    (`SCRunningApplication.bundleIdentifier` is populated from the
    process's own containing bundle — same relationship, walked in the
    opposite direction). Verified with a real link + run (not just
    `-fsyntax-only`): `CGWindowListCopyWindowInfo`/`CFBundleCreate`/
    `proc_pidpath` all resolve against the framework set already linked
    (`ApplicationServices` pulls in CoreGraphics'/CoreFoundation's headers
    transitively via `CoreServices`, `libproc` is in `libSystem`) — no new
    `-framework` flag needed, confirmed via `otool -L` showing an identical
    load-command set before/after this change. Dedup is by bundle id (a
    running app can have many on-screen windows); the process's own pid
    and any window whose owning pid's bundle id can't be resolved (e.g. a
    bundle-less helper/CLI process) are skipped.

## Real mode: how it works (Windows)

> **Status: implemented, CI-compiled against the real pinned SDK, NOT yet
> run on real Windows hardware.** Everything below is either verified
> directly against the pinned obs-studio 32.1.2 source (fetched read-only
> for this task — `plugins/win-capture/`, `plugins/win-wasapi/`,
> `plugins/obs-nvenc/`, `plugins/obs-qsv11/`, `plugins/obs-x264/`,
> `plugins/obs-ffmpeg/`, `libobs/obs-windows.c`, `libobs/util/windows/
> window-helpers.c`) or clearly flagged as an assumption. A Windows tester
> should treat every claim here as "needs confirming", not "confirmed".

`rewind_obs_init` does, in order (paralleling the macOS steps above):

1. **No permission gate.** Unlike macOS's Screen Recording TCC prompt,
   Windows has no runtime permission the shim needs to request for screen
   capture.
2. **Locate the SDK.** `find_obs_sdk_dir()` tries: a `REWIND_OBS_SDK_DIR`
   compile-time define (not currently set by any build step, same as
   macOS); `<shim dll dir>` itself (the packaged layout —
   `tools/bundle_obs_windows.ps1` drops `obs-plugins/`+`data/` directly
   beside the compiled `rewind_obs.dll`, no nested-framework indirection
   like macOS, since Flutter's Windows toolchain places a compiled
   dart:ffi code asset as a flat DLL next to the built `.exe`); walking up
   from the shim's own directory looking for `native/third_party/obs`
   (dev-tree `flutter run`/`flutter build windows` runs, before bundling).
   The shim's own directory is resolved via
   `GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS)` +
   `GetModuleFileNameW` — the Win32 analogue of macOS's `dladdr`.
3. **`obs_startup`**, then **`obs_add_data_path()`** with
   `<sdk_dir>/data/libobs/` — see "libobs' own core data" below for why
   this is needed on Windows but not macOS — then
   **`obs_reset_video`/`obs_reset_audio`**. `graphics_module` is an
   absolute path to **`libobs-d3d11.dll`**, not `libobs-opengl.dll` — see
   "Deviations" below.
4. **`obs_add_module_path`** for `<sdk>/obs-plugins/64bit/%module%.dll` +
   `<sdk>/data/obs-plugins/%module%` (flat templates — no `.plugin` bundle
   nesting), then `obs_load_all_modules()` + `obs_post_load_modules()`.
5. **Capture source**: `monitor_capture` (a display, DXGI-duplication
   backed since the shim always forces a D3D11 render device — see below)
   or `window_capture` (a window/app) — two distinct source ids, switched
   between via `rebuild_video_capture()` (destroys+recreates on a category
   change, updates in place within one). `game_capture` was deliberately
   not used — see "Why not `game_capture`" below.
6. **Audio**: `wasapi_output_capture` (desktop) / `wasapi_process_output_capture`
   (per-app, Windows 10 20H1+) on channel 1, `wasapi_input_capture` (mic) on
   channel 2 — mirroring `rebuild_system_audio()`'s macOS shape exactly,
   same fail-closed "no target -> silence, not leaked desktop audio"
   behavior.
7. **Encoders**: a hardware-first fallback ladder —
   `obs_nvenc_h264_tex` (NVIDIA) → `h264_texture_amf` (AMD) →
   `obs_qsv11_v2` then `obs_qsv11` (Intel Quick Sync) → `obs_x264`
   (software) — `create_video_encoder()` tries each in turn via
   `obs_video_encoder_create()`, using whichever succeeds first. Audio is
   `ffmpeg_aac` (see "Why not `CoreAudio_AAC`" below).
8. **Replay buffer output** (`replay_buffer`, from `obs-ffmpeg`) — same
   source id and settings keys as macOS (this part of the API is not
   platform-specific).

### Why not `game_capture`

OBS's `game_capture` source (the highest-fidelity option for capturing a
specific game window, with cursor/overlay compositing) works by injecting a
hook DLL into the target process (`graphics-hook32/64.dll`, loaded via a
helper injector). That is exactly the kind of process hooking
`docs/COMPLIANCE.md` rules out — it is indistinguishable from what a
kernel-level anti-cheat (Vanguard, EAC, BattlEye) watches for, and using it
risks getting a user's game account flagged or banned. `window_capture`
(BitBlt or Windows Graphics Capture, chosen automatically by libobs, no code
injected into the target process) is the safer fit and is what this shim
uses for app/window targeting; `monitor_capture` for whole-display capture
is likewise injection-free. This is a deliberate scope decision, not an
oversight — the task brief that produced this file offered `game_capture` as
an option, and it was rejected on compliance grounds.

### Why not `CoreAudio_AAC`

`coreaudio-encoder` (the plugin providing the `CoreAudio_AAC` encoder id
macOS uses) *does* have a Windows build target in this libobs tree — but
only by dynamically loading Apple's proprietary `CoreAudioToolbox.dll` at
runtime (historically redistributed with iTunes/Apple Application Support,
not present on a stock Windows install). Rewind has no license to
redistribute that DLL, and requiring users to separately install Apple
software to get audio would be a bad experience even if it were legal. The
shim uses `ffmpeg_aac` (libavcodec's built-in AAC encoder, part of
`obs-ffmpeg` — already bundled for the muxer) instead; no extra dependency,
no licensing question.

### `mac-videotoolbox`-equivalent gap: none

Unlike macOS (where the H.264 encoder needed a separate plugin,
`mac-videotoolbox`, added to the fetch allow-list before it worked), every
Windows encoder candidate (NVENC, AMF, QSV, x264) is provided by plugins
already in this shim's allow-list (`obs-nvenc`, `obs-ffmpeg`, `obs-qsv11`,
`obs-x264` — see `tools/fetch_libobs_windows.ps1`). There is no equivalent
"missing plugin" gap by construction, though whether NVENC/AMF/QSV
*actually* register on a given machine depends on that machine's GPU driver
— untested, see the report at the end of this task.

## Deviations from a naive port (Windows)

Verified against the real headers/source at the pinned tag (32.1.2),
fetched read-only for this task (not assumed from memory) — same rigor as
the macOS section above, but **without the ability to compile or run any of
it** (this work was done entirely on macOS; see the top-of-file status
note):

- **`graphics_module` must be `libobs-d3d11.dll`, not `libobs-opengl.dll`.**
  Two independent reasons, both traced through source: (1)
  `plugins/win-capture/plugin-main.c`'s `obs_module_load()` only registers
  the modern DXGI-duplication `monitor_capture` (the "monitor_id"-string
  variant this shim targets) when `gs_get_device_type() ==
  GS_DEVICE_DIRECT3D_11`; with any other render device it falls back to the
  legacy GDI `monitor_capture` (an `int` "monitor" index setting instead —
  NOT what this shim writes, so display capture would silently target the
  wrong/no monitor). (2) NVENC (`plugins/obs-nvenc/nvenc-d3d11.c`) and AMF
  (`plugins/obs-ffmpeg/texture-amf.cpp`) hardware encoding is texture-based
  and needs a D3D11 device to hand off GPU textures without a CPU round
  trip — without it, this shim's encoder ladder would always fall through
  to software x264 even on a machine with a perfectly good GPU.
- **`monitor_capture`'s real settings key is `"monitor_id"` (a device-id
  string), not `"monitor"` (an int index).** There are actually TWO
  `monitor_capture`-id sources in this tree: the legacy GDI one
  (`plugins/win-capture/monitor-capture.c`, `"monitor"` int, chosen when the
  render device isn't D3D11) and the modern DXGI-duplication one
  (`plugins/win-capture/duplicator-monitor-capture.c`, `"monitor_id"`
  string) — both register under the identical id `"monitor_capture"`, and
  which one wins is decided by `win-capture`'s `obs_module_load()` at
  runtime based on the render device (see above). Since this shim always
  forces D3D11, the "monitor_id" variant is the one that will actually be
  live — confirmed the string this shim computes matches exactly what
  `duplicator-monitor-capture.c`'s own device-id derivation produces
  (`EnumDisplayDevicesA(..., EDD_GET_DEVICE_INTERFACE_NAME)`, falling back
  to the raw `MONITORINFOEXA::szDevice` string on failure — see
  `get_monitor_device_id()` in `rewind_obs_windows.c`).
- **`window_capture`/`wasapi_process_output_capture`'s `"window"` setting
  is an opaquely-encoded `"title:class:exe"` string**, NOT a window
  handle — confirmed against `libobs/util/windows/window-helpers.c`'s
  `encode_dstr()`/`add_window()`/`ms_build_window_strings()`: `'#'` ->
  `"#22"` then `':'` -> `"#3A"` (in that order — encoding `':'` first would
  corrupt the `"#3A"` escape sequence's own colon), the three components
  joined by literal `:`. `build_window_token()` in `rewind_obs_windows.c`
  reproduces this exactly (its intermediate/output buffers were enlarged in
  a later refactor to round-trip a max-length window title without
  truncation — see that file's comment at `RW_WIN_ET_CAP`). Rewind's
  `rewind_list_capturable_apps()` emits
  this token AS the (otherwise macOS-bundle-id-shaped) `"bundle_id"` JSON
  field — an intentional repurposing of an opaque string field, not a type
  mismatch: `rewind_set_capture_app()` just round-trips whatever string it
  was given straight back into libobs, and neither the Dart side nor the
  header contract cares what the string actually encodes.
- **`"window_id"` is the HWND itself, truncated to 32 bits — lossless on
  64-bit Windows.** Unlike macOS's `CGWindowID` (already a 32-bit integer),
  a 64-bit Windows `HWND` is a pointer-sized handle. Microsoft's own
  interoperability documentation states the top 32 bits of any 64-bit
  Win32 handle (including `HWND`) are always zero specifically so 32-bit
  and 64-bit processes can exchange them — so `(uint32_t)(uintptr_t)hwnd`
  loses nothing in practice. `rewind_set_capture_window()` reverses this
  with `(HWND)(uintptr_t)window_id` (zero-extension, not sign-extension —
  correct given the value only ever came from truncating a real handle).
- **`monitor_capture` and `window_capture` are different source ids —
  switching between "capture a display" and "capture a window/app" cannot
  be a plain `obs_source_update()`* the way macOS's single `screen_capture`
  source (switched via its `"type"` setting) can. `rebuild_video_capture()`
  tracks which kind currently backs `g_capture` (`g_win_capture_kind`) and
  destroys+recreates the source on a category change, updating in place
  only within the same category. This is the single biggest structural
  difference from the macOS capture-source code.
- **libobs' own core data (`default.effect` and the other built-in
  shaders) needs an explicit `obs_add_data_path()` call — the opposite of
  macOS, where none is needed.** Traced through `libobs/obs-windows.c`:
  `find_libobs_data_file()` (tried first by `obs_find_data_file()`) is
  hardcoded to the *relative* path `"../../data/libobs/"`, resolved via a
  plain `os_file_exists()` — i.e. against the process's **current working
  directory**, not the executable's or `obs.dll`'s own directory. That
  assumes OBS Studio's own installed layout (`bin/64bit/obs64.exe` launched
  with its own directory as CWD, so `../../data/libobs` lands two levels
  up) — which doesn't hold for `tools/bundle_obs_windows.ps1`'s flat
  bundling next to `rewind.exe`, and Rewind has no control over the
  process's CWD at launch regardless (Explorer/shortcut "Start in"
  dependent). Rather than fight that, `rewind_obs_init()` calls the public
  `obs_add_data_path()` API directly with `<sdk_dir>/data/libobs/` right
  after `obs_startup()` (before `obs_reset_video()`, the first thing that
  actually loads these effects) — `obs_find_data_file()` falls back to
  every path added this way when `find_libobs_data_file()` doesn't resolve,
  so this doesn't depend on that CWD-relative lookup succeeding at all.
- **Encoder ids are NOT the ones a naive port of the task brief would use.**
  The brief suggested `jim_nvenc`/`ffmpeg_nvenc` for NVIDIA — `jim_nvenc` is
  a since-renamed legacy id; the pinned tag's actual NVENC plugin
  (`plugins/obs-nvenc/nvenc.c`) registers `obs_nvenc_h264_tex` (texture) and
  `obs_nvenc_h264_soft` (non-texture fallback, not currently tried by this
  shim — texture mode is expected to work whenever a D3D11 device is live,
  which this shim always requests). `ffmpeg_nvenc` also still exists (in
  `obs-ffmpeg`) as an older/alternate NVENC path but isn't used here in
  favor of the dedicated `obs-nvenc` module's id. AMD's real id is
  `h264_texture_amf`, registered by `obs-ffmpeg.dll` itself (`plugins/
  obs-ffmpeg/texture-amf.cpp`) — there is no separate `obs-amf` plugin in
  this tree, unlike what the brief assumed. Intel QSV's real ids are
  `obs_qsv11_v2` (texture, tried first) and `obs_qsv11` (legacy fallback),
  both from `plugins/obs-qsv11/obs-qsv11.c`. `obs_x264`
  (`plugins/obs-x264/obs-x264.c`) matched the brief. All confirmed by
  grepping `.id = "..."` registrations directly in the pinned-tag source,
  not assumed.
- **`fetch_libobs_windows.ps1`'s prebuilt-runtime-zip approach, not a
  source build.** Unlike macOS (which builds libobs from source via CMake +
  Xcode), there's no per-platform reason Windows *couldn't* also build from
  source — but obs-studio's Windows CMake path needs the full Visual Studio
  build tooling and a much longer configure/build (no CI-friendly ~2-minute
  turnaround like the macOS recipe), and — critically — the official
  project already publishes a prebuilt, pinned-tag Windows runtime `.zip`
  for exactly this platform, which macOS does not (Apple's notarization
  requirements make an unsigned prebuilt macOS zip far less useful). Using
  it directly is both faster and lower-risk than reproducing obs-studio's
  own Windows CMake configuration by hand. The one thing the runtime zip
  lacks — an import library to link against — is synthesized from the
  DLL's own export table (see `tools/fetch_libobs_windows.ps1`'s header
  comment for exactly how, and why that's a standard, safe technique).

## Wiring up real libobs

1. `tools/fetch_libobs.sh` (macOS) or `tools/fetch_libobs_windows.ps1`
   (Windows) lays out the SDK at `native/third_party/obs/` (gitignored).
   On macOS, see the gap above — `mac-videotoolbox` needs adding to its
   plugin allow-list before a fetch produces a fully working encoder set.
   On Windows there's no equivalent gap (see "`mac-videotoolbox`-equivalent
   gap: none" above).
2. Build the shared library:

   **macOS**
   ```bash
   clang -shared -fPIC native/shim/rewind_obs.c native/shim/rewind_obs_macos.c \
     -o librewind_obs.dylib \
     -DREWIND_USE_LIBOBS -Inative/third_party/obs/include \
     -Fnative/third_party/obs/lib -framework libobs \
     -framework ApplicationServices
   ```
   (verified: syntax-checks clean and links successfully as of this task;
   the resulting dylib's only unresolved load command is
   `@rpath/libobs.framework/Versions/A/libobs`, which Task 10's app
   bundling needs to satisfy via an `@rpath`/`Frameworks/` setup.)

   **Windows (MSVC)** — implemented, not yet compiled/run against real
   hardware (see the Windows section above). `hook/build.dart` runs the
   equivalent of this automatically; shown here for reference / manual
   debugging outside the Dart build hook:
   ```bat
   cl /c /I native\third_party\obs\include /DREWIND_USE_LIBOBS ^
     native\shim\rewind_obs.c native\shim\rewind_obs_windows.c
   link /DLL /OUT:rewind_obs.dll rewind_obs.obj rewind_obs_windows.obj ^
     /LIBPATH:native\third_party\obs\lib obs.lib user32.lib dwmapi.lib
   ```

3. Place the resulting library where the app can `DynamicLibrary.open` it
   (next to the executable / inside the `.app` bundle). Ship libobs'
   runtime `data/` and `obs-plugins/` alongside — see ARCHITECTURE.md →
   Packaging.

## Licensing

Linking libobs makes the whole app GPLv3. Keep this shim GPLv3 and free of
GPL-incompatible dependencies.
