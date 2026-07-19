# Architecture

This document describes how Rewind is put together and why.

## Goals

- One codebase, native performance, Windows, macOS, **and** Linux (the
  Linux capture backend is implemented and CI-compiled; a distributable
  Linux app is not yet assembled — see "Packaging" below and ROADMAP.md).
- Reuse a proven capture/encode pipeline instead of reinventing it — hence embedded **libobs**.
- Keep the native surface tiny so almost all work happens in testable Dart.

## Layers

### 1. Flutter / Dart (application)

Owns everything the user sees and most of the logic:

- **UI** (`lib/src/ui/`) — a game-centric shell: a persistent left rail
  (games as first-class destinations, built by `game_directory.dart`), a
  recorder deck (buffer state, capture-source picker, save), per-game hub
  screens (clips, matches, detection status, and a glanceable
  capture-settings summary card), a supported-games catalog, in-app player
  (media_kit), and tray presence. Settings is a **full-page screen** with
  its own sidebar (GENERAL pages + a MY GAMES page per configured game —
  all per-game editing lives there; the hub card links into it). Design
  system: `RewindTokens` in `theme.dart`; base spec in
  `docs/superpowers/specs/2026-07-13-game-centric-redesign.md`, settings
  redesign rationale in the 2026-07-18 research pass (variants artifact).
- **Event watchers** (`lib/src/events/`) — per-game sources that emit `GameEvent`s. THREE source SHAPES exist so far: `LeagueEventWatcher`, which polls a **local, cert-pinned** HTTPS endpoint at `https://127.0.0.1:2999/liveclientdata/eventdata` (no credentials, only exists mid-match); `SteamAchievementWatcher`, which polls the **public, credentialed** Steam Web API (`api.steampowered.com`) for achievement unlocks — kept in the tree but no longer constructed, see below; and `SteamStatsWatcher` (maintainer decision 2026-07-19, replacing the Web API watcher as `source_builder.dart`'s actual Steam source), a **local file watcher**: no credentials, no network, discovers every Steam install on the machine and watches its `appcache/stats/` cache directly for achievement unlocks. All three are generic across EVERY Steam/League game rather than one title where applicable, and (Steam sources only) deliberately never "activate" through `GameRegistry`'s normal `isGameRunning` tick (they drive no capture/buffer-policy signal of their own; events are attributed to whatever game is otherwise detected active). See each class's doc for the full contrast.
- **Clip coordinator** — subscribes to watchers and the global hotkey; decides when to call the capture engine to save a clip; records metadata into the clip library.
- **FFI bindings** (`lib/src/obs/`) — thin Dart wrappers over the C shim,
  behind a small **`CaptureEngine`** interface. The coordinator and UI depend
  only on `CaptureEngine`; `RewindObsEngine` implements it over the `@Native`
  bindings, and tests use a fake — so `flutter test` never needs the native
  library, and an alternate capture backend stays possible.

### 2. Rewind C shim (`native/shim/`)

A small, stable C11 API (no C++, so `dart:ffi` binding is trivial — no name mangling). It hides all libobs setup and exposes only:

Internally the shim is split by platform: `rewind_obs.c` holds the shared API layer + no-libobs stub, `rewind_obs_internal.h` declares the `rw_plat_*` backend interface, and `rewind_obs_macos.c`/`rewind_obs_windows.c`/`rewind_obs_linux.c` each implement that interface for one platform (see `native/shim/README.md`). No `#ifdef __APPLE__`/`_WIN32`/`__linux__` "backend selection" walls exist in the shared file — each backend was dropped in purely by implementing the `rw_plat_*` interface, no changes needed there.

| Function | Purpose |
|----------|---------|
| `rewind_obs_init(const RewindConfig*)` | Start libobs, create video/audio, pick capture source, configure replay buffer |
| `rewind_start_buffer()` | Begin the rolling replay buffer |
| `rewind_save_clip(const char* out_dir)` | Flush the last N seconds to a file; returns path |
| `rewind_stop_buffer()` | Stop buffering |
| `rewind_obs_shutdown()` | Tear down libobs |
| `rewind_last_error()` | Human-readable last error string |

The shim is where OS-specific capture selection happens: on macOS it configures a ScreenCaptureKit-based source, on Windows a DXGI-duplication/Windows-Graphics-Capture source — but that choice is internal; the Dart-facing API is identical.

**Windows capture path** (implemented, CI-compiled against the real pinned
libobs SDK, **not yet validated on real Windows hardware** — see ROADMAP.md):

- **Video sources:** `monitor_capture` (a display, keyed by a `monitor_id`
  device-id string) and `window_capture` (a specific window/app, keyed by an
  encoded `"title:class:exe"` token) — two distinct libobs source ids, unlike
  macOS's single `screen_capture` source with a `type` switch. Switching
  between "capture a display" and "capture a window/app" therefore recreates
  the source; switching within a category (one monitor to another, one app
  window to another) just updates it in place. `game_capture` (hook-injection
  based capture) was deliberately **not** used for app/window targeting,
  even though it's the highest-fidelity option OBS itself offers for games:
  it works by injecting a hook DLL into the target process, which is exactly
  the kind of hooking `docs/COMPLIANCE.md` rules out for anti-cheat safety —
  `window_capture` (BitBlt/Windows-Graphics-Capture, no injection) is the
  safer fit and is what Rewind uses.
- **Audio:** `wasapi_output_capture` (desktop, "ALL" mode) and
  `wasapi_input_capture` (mic) as on any WASAPI setup; "APP" mode uses
  `wasapi_process_output_capture` (per-process WASAPI loopback, Windows 10
  20H1+), falling back to silence — not desktop audio — if no app target is
  set, same fail-closed principle as macOS's `rebuild_system_audio()`.
- **Encoders:** a hardware-first fallback ladder — NVIDIA (`obs_nvenc_h264_tex`)
  → AMD (`h264_texture_amf`) → Intel Quick Sync (`obs_qsv11_v2` then
  `obs_qsv11`) → software x264 (`obs_x264`) — tried in order via
  `obs_video_encoder_create()`, whichever succeeds first wins. Audio is
  `ffmpeg_aac` (libavcodec's built-in AAC encoder, bundled with the muxer
  anyway) rather than the `CoreAudio_AAC` id macOS uses: that id *does* build
  on Windows in this libobs tree, but only by dynamically loading Apple's
  proprietary CoreAudioToolbox.dll at runtime, which Rewind has no license to
  redistribute and which isn't present on a stock Windows machine.
- **Module/data paths:** `obs_add_module_path()` with flat
  `obs-plugins/64bit/%module%.dll` + `data/obs-plugins/%module%` templates
  (vs. macOS's `.plugin` bundle nesting). libobs' own core data (shader
  effects) needed a separate fix: its Windows lookup
  (`find_libobs_data_file()`) is hardcoded to a path *relative to the
  process's current working directory*, which doesn't hold for Rewind's flat
  bundling — so the shim calls the public `obs_add_data_path()` API directly
  with an absolute path instead of relying on that fallback. Both the SDK
  directory and the graphics render device (`libobs-d3d11.dll`, not
  `libobs-opengl.dll` — needed for NVENC/AMF's zero-copy GPU-texture
  hand-off) are resolved with a dev-tree-vs-packaged-layout fallback mirroring
  macOS's own `find_obs_sdk_dir()`/`find_graphics_module_path()`. See
  `native/shim/README.md` for the full trace with source citations.

**Linux capture path** (implemented, CI-compiled on a real Ubuntu runner
against the real pinned libobs SDK, **not yet run on any real Linux
desktop** — see ROADMAP.md):

- **Two capture models, chosen per session type.** Linux has no single
  capture API the way macOS (ScreenCaptureKit) and Windows (DXGI/WGC) do —
  X11 and Wayland are structurally different. The shim detects the session
  via `WAYLAND_DISPLAY` and picks accordingly (see `native/shim/README.md`'s
  Linux section for the full trace).
- **X11**: `xshm_input_v2` (a display, keyed by a RandR monitor index) and
  `xcomposite_input` (a specific window, keyed by its XID) — the same
  two-source-id structural split as Windows' `monitor_capture`/
  `window_capture`. X11 has no "capture this application" concept
  distinct from a window, so app targeting and window targeting collapse
  into the same mechanism (unlike macOS/Windows, which each have a
  separate app-level target).
- **Wayland**: a single portal-backed source
  (`pipewire-screen-capture-source`, from `xdg-desktop-portal` + PipeWire)
  whose picker dialog is shown to the user interactively when capture
  starts — there is no settings key to preselect a display/window/app the
  way X11 or the other two platforms support, so display/app/window
  enumeration and the capture-target setters are no-ops on Wayland,
  documented rather than silently swallowed.
- **Audio**: `pulse_output_capture` (desktop, "ALL" mode) / `pulse_input_capture`
  (mic). Linux has **no per-application PulseAudio source** in this SDK —
  "APP" audio mode falls back to full desktop audio with a logged warning,
  a deliberate platform-capability decision (see `native/shim/README.md`).
- **Encoders**: a hardware-first ladder — NVIDIA (`obs_nvenc_h264_tex`) →
  Intel/AMD VA-API (`ffmpeg_vaapi_tex` then `ffmpeg_vaapi`) → software x264
  (`obs_x264`); audio is `ffmpeg_aac` (same reasoning as Windows: no
  `CoreAudio_AAC`-equivalent licensing question).
- **Build**: `tools/fetch_libobs_linux.sh` builds libobs + this plugin set
  from source via CMake/Ninja against system X11/XCB/PipeWire/PulseAudio/
  FFmpeg dev packages (unlike Windows' prebuilt-zip repackaging — there is
  no upstream Linux runtime artifact meant for embedding). `hook/build.dart`
  links the shim against it directly (`-lobs`, no import-lib indirection
  needed on ELF).
- **Flutter Linux desktop plugin support** (outside the shim, not fixed by
  this work — see ROADMAP.md for the full gap list): `hotkey_manager`,
  `tray_manager`, `media_kit`/`media_kit_video`, and `file_selector` all
  declare Linux support, but `hotkey_manager` needs `keybinder-3.0`,
  `tray_manager` needs `libayatana-appindicator3` AND won't show an icon on
  stock GNOME without the user installing a Shell extension, and
  `media_kit` needs `libmpv` present on the system (not bundled) — none of
  these are libobs/shim concerns, but they block a real Linux app beyond
  what this shim provides.

### 3. libobs (vendored/linked)

Provides capture, hardware encoding (NVENC/AMF on Windows, VideoToolbox on macOS), and the replay buffer output. Rewind links against libobs and ships its required runtime data (plugins, effect files, locale). See "Packaging" below.

## Data flow: an automatic League clip

```
LeagueEventWatcher (Dart)
   │  polls 127.0.0.1:2999 every ~250ms while in-game
   ▼
GameEvent(kind: pentaKill, t: ...)     ── emitted on stream
   │
   ▼
ClipCoordinator (Dart)
   │  event kind is enabled in settings?
   ▼  yes → rewind_save_clip("~/Movies/Rewind")   (via FFI)
   │
   ▼
C shim → obs_frontend/replay output flush  →  clip.mp4 written
   │
   ▼
ClipCoordinator records Clip(path, event, timestamp) → library / UI
```

Manual hotkey path is identical minus the watcher: hotkey → coordinator → `rewind_save_clip`.

## Threading

- libobs runs its own capture/encode threads; the shim calls are non-blocking control calls.
- Dart event watchers run on the Dart event loop (async HTTP). Nothing heavy runs on the UI isolate.
- FFI calls that could block (init/shutdown) should be marshalled off the UI isolate where needed.

## Packaging (the fiddly part)

libobs is not a single static blob — it needs runtime data and plugin modules present at known paths relative to the executable.

- **The SDK itself** is built once by `tools/fetch_libobs.sh` (pinned
  obs-studio tag + matching obs-deps; only libobs and the four plugin modules
  Rewind needs) into git-ignored `native/third_party/obs/`. When that
  directory exists, `hook/build.dart` compiles the shim with
  `REWIND_USE_LIBOBS` and links `libobs.framework`; when absent, the
  self-contained stub compiles instead, so contributors and CI need zero
  native setup for tests and UI work.
- **macOS:** libobs ships as a real `.framework` (its plugins hard-link
  `@rpath/libobs.framework/...`). `tools/bundle_obs_macos.sh` copies the
  framework + dylib closure into `Rewind.app/Contents/Frameworks/` and the
  `obs-plugins/` + `data/` trees into `Contents/Resources/obs/`, then ad-hoc
  re-signs the app. The shim discovers those paths at runtime relative to its
  own location (`dladdr`), falling back to `native/third_party/obs/` for
  dev-tree runs. Distribute as a signed, notarized `.app` in a DMG (v1.0).
- **Windows:** `tools/fetch_libobs_windows.ps1` assembles a libobs SDK under
  `native/third_party/obs/` from two official, pinned obs-studio release
  artifacts (there's no upstream "Windows SDK" package): the prebuilt
  Windows portable runtime zip (DLLs — obs.dll, the six plugin DLLs Rewind
  uses, their runtime dependencies) and the matching Sources tarball
  (`libobs/**/*.h` only, for headers). Since the runtime zip ships no
  import library, `obs.lib` is synthesized from `obs.dll`'s own export
  table via `dumpbin /exports` + a generated `.def` + `lib.exe` — the
  standard technique for linking against a DLL-only artifact (needs a
  Visual Studio Developer environment; see the script and
  `native/shim/README.md`). `tools/bundle_obs_windows.ps1` then copies
  `obs.dll` + its runtime DLLs flat next to the built `rewind.exe`,
  `obs-plugins/64bit/` nested (matching `setup_module_paths()`'s module-bin
  template), and `data/` nested (matching its data template + the
  `obs_add_data_path()` call `rewind_obs.c` makes on Windows — see below);
  package with Inno Setup (`tools/windows_installer.iss`).
- **Linux:** `tools/fetch_libobs_linux.sh` builds `native/third_party/obs/`
  from source (CMake/Ninja) against the same narrow plugin allow-list as
  the other two platforms. **No `tools/bundle_obs_linux.sh` exists yet** —
  packaging a runnable Linux bundle (copying `libobs.so`/`libobs-opengl.so`/
  plugins/data next to a built executable, plus resolving the Flutter
  plugin gaps noted above) was out of scope for the task that added this
  backend; CI only compiles `flutter build linux --debug` against the real
  SDK (`build-linux-libobs` in `ci.yml`), it doesn't produce a distributable
  artifact. See ROADMAP.md.

CI release jobs assemble these bundles per platform. See `.github/workflows/release.yml`.

## Why not just talk to an external OBS (obs-websocket)?

That was the fast-MVP alternative (drive an installed OBS over WebSocket, no native code). We chose embedding libobs instead for a single self-contained app with no separate OBS install. The trade-offs: more native/packaging work, and the whole app must be GPLv3 — both accepted, since Rewind is open source. The `obs-websocket` approach remains a possible fallback backend if embedding proves too heavy on a given platform; the `ClipCoordinator` → capture-engine boundary is deliberately abstract enough to swap.

## Licensing note

Embedding libobs (GPLv3) makes Rewind a GPLv3 work as a whole. This is intentional and fine — Rewind is free/open-source software. Do not introduce GPL-incompatible dependencies.

Third-party dependencies with license relevance, checked GPLv3-compatible:

- **media_kit / media_kit_video / media_kit_libs_video** (in-app playback):
  Dart packages are MIT; the bundled native **libmpv** is LGPL v2.1 —
  compatible. (`fvp` was evaluated and rejected: its libmdk core is
  proprietary/key-gated, GPL-incompatible.)
- **talker_flutter** (logging + in-app log screen): MIT.
- **hotkey_manager / tray_manager / path_provider / http / ffi / path**: MIT/BSD.

When adding a dependency, record its license here if it ships native code or
is anything other than a routine MIT/BSD pub package.

## Game integration plugins (extensibility)

Rewind is designed so **new games plug in without touching the capture engine or core app**. Every integration implements one interface:

```dart
abstract class GameEventSource {
  String get gameId;                 // e.g. "league_of_legends"
  String get displayName;
  Future<bool> isGameRunning();      // cheap probe (process/API/port)
  Stream<GameEvent> events();        // emits while the game is active
  Future<void> start();
  Future<void> stop();
}
```

A `GameRegistry` holds all known sources. A lightweight supervisor loop asks each registered source `isGameRunning()`; when one becomes active it `start()`s that source and pipes its events into the `ClipCoordinator`. Multiple sources can be active at once (**cross-game** support), and a built-in generic source provides manual-hotkey capture for any game or the whole desktop with no integration at all.

Adding a game = add one `GameEventSource` implementation + register it. See CONTRIBUTING.md.

```
GameRegistry
 ├── LeagueEventWatcher      (127.0.0.1:2999)
 ├── <YourGame>EventWatcher  (log tail / local API / memory)
 └── GenericManualSource     (hotkey only, any game/desktop)
        │  all emit GameEvent
        ▼
   ClipCoordinator ──► capture engine (save clip)
```

### Adding a game (the `GameDescriptor` recipe)

Task 21 collapsed what used to be ~11 scattered hardcoded-League-id sites
(match presentation, the directory merge, the hub, Supported Games, icon
policy, event groups) into one registry: `lib/src/games/game_descriptor.dart`.
Adding a new game now follows one of two paths:

1. **Process-detection only (the common case — most new games, e.g. Marvel
   Rivals):** add one `CatalogGame` entry to `popularGamesCatalog`
   (`lib/src/events/game_catalog.dart`) with its `gameId` (`app:<slug>`),
   `displayName`, and `processMatch` (the real running-process/exe basename —
   verify it against the actual binary, not the launcher). **No
   `GameDescriptor` entry needed** — `descriptorFor` synthesizes a sane
   default (single merged id, `usesOfficialLogo: true`, no presentation, no
   event groups, no live feed) straight from the catalog entry. Only add an
   explicit `GameDescriptor` if this game deviates from that default — e.g. a
   `usesOfficialLogo: false` override for a publisher with no fan-tool logo
   carve-off (Marvel Rivals; see docs/COMPLIANCE.md's per-game notes).
2. **A sanctioned vendor API OR local file (rare — League is the only
   per-game-API fit; the Steam integrations are cross-game ones with no
   single `gameId` of their own to attach a `GameDescriptor` to — see the
   events layer bullet above):**
   implement `GameEventSource` and register it (`source_builder.dart`,
   `game_registry.dart` — see the section above), THEN add a `GameDescriptor`
   entry with `mergedGameIds` covering both the vendor id and any catalog
   entry for the same game's client/launcher, `hasLiveFeed: true` +
   `detailCopy` (the hub's connected/waiting prose), `eventGroups` (the
   auto-clip taxonomy), and optionally `presentationFactory` for a per-game
   match drill-down (`match_presentation.dart`).

`gameDescriptors` documents its own "registry holds only deviations from the
default" contract — read that doc comment before adding an entry.

**Deliberately NOT extracted (YAGNI) as part of Task 21**, despite being
League-specific today: `PollingEventWatcher`'s base polling loop and the
per-game stats model (`clip/match_stats.dart`) are written directly against
League's shape. Generalizing either into a seam now would be speculative —
there is exactly one vendor-API integration to generalize FROM. Extract them
when a second sanctioned vendor API actually lands, informed by its real
constraints instead of guessed ones.

Task 22 (`SteamAchievementWatcher`) IS that second vendor-API integration,
and the YAGNI call above still stands even with two data points: League
polls ONE local, uncredentialed, cert-pinned endpoint per match, seeded via
`activeplayername`/`playerlist`, driving `GameRegistry` activation directly.
Steam polls a public, credentialed API across TWO tiers (presence,
achievements) with no OS-level activation signal at all (see the events
layer bullet above) and its own vanity-id resolution/backoff/status-mapping
concerns. The only real overlap is the "seed on first poll, diff after"
pattern (the League 44 MB lesson) and a poll re-entrancy guard — both are a
few lines each, copied rather than shared. Revisit extraction if/when a
THIRD vendor-API source lands and the overlap looks like more than that.

## Storage-aware clip library

Recording continuously and auto-clipping generates a lot of video, so storage management is a first-class feature, not an afterthought.

- **`Clip`** carries metadata: path, game, event kind, timestamp, size, and a **`protected`/`pinned`** flag.
- **`StorageManager`** enforces a user-configured policy:
  - a **disk budget** (e.g. "use at most 20 GB for clips"), and/or
  - a **time window** (e.g. "keep the last 14 days"), and/or
  - **per-event caps** (e.g. "keep at most 50 simple-kill clips").
- When a policy is exceeded, the manager prunes the **oldest, unprotected** clips first until back within budget.
- **Protected/pinned clips are never auto-deleted** — the user can pin a highlight and trust it stays. Manual deletion is always allowed.
- Pruning runs after each new clip is saved and on a periodic sweep; it is idempotent and safe to run often.

```
new clip saved ──► StorageManager.enforce()
                     │  over budget?
                     ▼  yes
                   sort unprotected clips oldest-first
                     │  delete until within budget (skip protected)
                     ▼
                   ClipLibrary updated, UI storage meter refreshed
```
