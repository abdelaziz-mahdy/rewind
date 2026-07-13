# Architecture

This document describes how Rewind is put together and why.

## Goals

- One codebase, native performance, Windows **and** macOS.
- Reuse a proven capture/encode pipeline instead of reinventing it — hence embedded **libobs**.
- Keep the native surface tiny so almost all work happens in testable Dart.

## Layers

### 1. Flutter / Dart (application)

Owns everything the user sees and most of the logic:

- **UI** (`lib/src/ui/`) — menu-bar/tray presence, settings, clip library.
- **Event watchers** (`lib/src/events/`) — per-game sources that emit `GameEvent`s. First implementation: `LeagueEventWatcher`, which polls the League **Live Client Data API** at `https://127.0.0.1:2999/liveclientdata/eventdata`.
- **Clip coordinator** — subscribes to watchers and the global hotkey; decides when to call the capture engine to save a clip; records metadata into the clip library.
- **FFI bindings** (`lib/src/obs/`) — thin Dart wrappers over the C shim,
  behind a small **`CaptureEngine`** interface. The coordinator and UI depend
  only on `CaptureEngine`; `RewindObsEngine` implements it over the `@Native`
  bindings, and tests use a fake — so `flutter test` never needs the native
  library, and an alternate capture backend stays possible.

### 2. Rewind C shim (`native/shim/`)

A small, stable C11 API (no C++, so `dart:ffi` binding is trivial — no name mangling). It hides all libobs setup and exposes only:

| Function | Purpose |
|----------|---------|
| `rewind_obs_init(const RewindConfig*)` | Start libobs, create video/audio, pick capture source, configure replay buffer |
| `rewind_start_buffer()` | Begin the rolling replay buffer |
| `rewind_save_clip(const char* out_dir)` | Flush the last N seconds to a file; returns path |
| `rewind_stop_buffer()` | Stop buffering |
| `rewind_obs_shutdown()` | Tear down libobs |
| `rewind_last_error()` | Human-readable last error string |

The shim is where OS-specific capture selection happens: on macOS it configures a ScreenCaptureKit-based source, on Windows a Windows Graphics Capture / duplication source — but that choice is internal; the Dart-facing API is identical.

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
- **Windows:** ship `obs.dll` + `obs-plugins/` + `data/` next to the `.exe`; package with an installer (MSIX or Inno Setup).

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
