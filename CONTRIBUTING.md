# Contributing to Rewind

Thanks for helping build Rewind! This guide covers setup and conventions.

## Prerequisites

- **Flutter SDK** with desktop support enabled:
  ```bash
  flutter config --enable-macos-desktop
  flutter config --enable-windows-desktop
  ```
- **A C toolchain**: Xcode command line tools (macOS) or MSVC Build Tools (Windows).
- **libobs**: a local build or SDK of libobs to link the shim against. See `native/shim/README.md`. Until the shim is wired to real libobs, it builds against a stub so the app runs in "no-capture" dev mode.
- **Windows only, for real capture**: a Visual Studio installation with the
  Desktop development with C++ workload (provides `dumpbin.exe`/`lib.exe`,
  needed by `tools/fetch_libobs_windows.ps1` — see "Real capture mode
  (Windows)" below).

## Getting started

```bash
git clone <repo-url> rewind
cd rewind
flutter pub get
flutter run -d macos    # or: flutter run -d windows
```

## Stub vs. real capture mode

`hook/build.dart` (the Dart build hook that compiles `native/shim/rewind_obs.c`)
picks the shim's implementation automatically, with **no manual flag**:

- **`native/third_party/obs/` absent (default for a fresh clone)** — the shim
  compiles as a self-contained **stub**: `rewind_obs_init`/`rewind_start_buffer`
  succeed trivially and `rewind_save_clip` synthesizes a plausible path without
  writing a file. This lets the whole Dart app (UI, hotkey, tray, clip library)
  be developed and tested without a libobs build at all.
- **`native/third_party/obs/` present** — the build hook defines
  `REWIND_USE_LIBOBS`, adds the SDK's `include/` dir, and links the shim
  against `lib/libobs.framework` (macOS only so far). This is the **real
  capture** path — see below to set it up.

## Real capture mode (macOS)

1. **Fetch the libobs SDK** (one-time; builds libobs from source, ~2 minutes
   on Apple Silicon, requires full Xcode — not just Command Line Tools):

   ```bash
   tools/fetch_libobs.sh
   ```

   This lays out a pinned libobs SDK under `native/third_party/obs/`
   (gitignored, ~90MB) — see the script's own comments for what it builds and
   why. Re-running is idempotent (a stamp file short-circuits it).

2. **Build/run normally** — the build hook now detects the SDK and links real
   libobs automatically:

   ```bash
   flutter run -d macos      # or: flutter build macos --debug
   ```

3. **Bundle libobs' runtime into the built `.app`.** Flutter's own build only
   compiles the shim and links it against the SDK in place; it does not copy
   libobs' framework, dylibs, plugins, or data files into the app bundle. Do
   that with:

   ```bash
   tools/bundle_obs_macos.sh build/macos/Build/Products/Debug/rewind.app
   ```

   This copies `native/third_party/obs/lib/*` (the `libobs.framework` plus its
   FFmpeg/x264/mbedTLS dylib closure) into `Contents/Frameworks/`, and
   `obs-plugins/` + `data/` into `Contents/Resources/obs/` — the layout
   `rewind_obs.c` expects for module loading — then ad-hoc re-signs the app
   (`codesign --force --deep -s -`; real signing/notarization is out of scope
   for v0.1). Safe to re-run against the same `.app`. See the script's header
   comment for a known gap: the Dart/Flutter macOS toolchain currently wraps
   the compiled shim in its own nested `rewind_obs.framework` rather than a
   flat dylib, which throws off the shim's packaged-app SDK path lookup for a
   truly relocated (moved outside the repo) app — dev-tree runs are
   unaffected.

4. **Grant the Screen Recording permission.** The first time the app actually
   tries to capture (creating/starting the `screen_capture` source), macOS
   gates it behind the **Screen Recording** TCC permission. Expect:
   - The app to appear (unchecked) under **System Settings → Privacy &
     Security → Screen Recording** after the first attempt.
   - Until you check it and **relaunch the app**, capture calls fail with a
     libobs log line like:
     ```
     warning: [ mac-screencapture ]: Unable to get list of available applications or windows. Please check if OBS has necessary screen capture permissions.
     error: [ mac-screencapture ]: init_screen_stream: Invalid target display ID:  <id>
     ```
     — this is expected and not a bug; grant the permission and relaunch.

## Real capture mode (Windows)

> **Unvalidated on real hardware.** This path was implemented and CI-compiled
> against the real pinned libobs SDK, but without access to a Windows
> machine to actually run it — see `native/shim/README.md`'s Windows section
> for exactly what's verified-by-source-reading vs. still assumption. If
> you're the first to try this on real hardware, please report back (open an
> issue) with what worked and what didn't.

1. **Open a Visual Studio Developer shell** (Start menu → "Developer
   PowerShell for VS 2022", or "x64 Native Tools Command Prompt" then launch
   `pwsh`) — `tools/fetch_libobs_windows.ps1` needs `dumpbin.exe`/`lib.exe`
   on `PATH` to synthesize an import library from the official prebuilt
   `obs.dll` (there's no upstream Windows dev SDK with headers + `.lib`
   files, only an end-user runtime `.zip` — see the script's own header
   comment for exactly what it downloads and why).

2. **Fetch the libobs SDK** (one-time; downloads ~200MB across two pinned
   GitHub release assets, no build from source):

   ```powershell
   ./tools/fetch_libobs_windows.ps1
   ```

   This lays out a pinned libobs SDK under `native/third_party/obs/`
   (gitignored) — same tag as the macOS pin (`32.1.2`). Re-running is
   idempotent (a stamp file short-circuits it).

3. **Build/run normally** — the build hook detects the SDK and links real
   libobs automatically:

   ```powershell
   flutter run -d windows       # or: flutter build windows --debug
   ```

4. **Bundle libobs' runtime into the built app.** Flutter's own build only
   compiles the shim and links it against the SDK in place; it does not copy
   `obs.dll`, the plugin DLLs, or `data/` into the runner output. Do that
   with:

   ```powershell
   ./tools/bundle_obs_windows.ps1 build/windows/x64/runner/Debug
   ```

   This copies the SDK's `bin/64bit/*` flat next to `rewind.exe`,
   `obs-plugins/64bit/` and `data/` nested alongside it — the layout
   `rewind_obs.c`'s Windows module-path/data-path code expects. Safe to
   re-run against the same build directory.

## Packaging installers

Tag-driven CI (`.github/workflows/release.yml`) builds these on every `v*`
tag, but you can produce them locally too:

- **macOS `.dmg`** (Apple Silicon):
  ```
  FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
    flutter build macos --release
  tools/package_macos_dmg.sh   # → dist/Rewind.dmg (pure hdiutil, no extra tools)
  ```
  The arm64-only flags are required: the fetched libobs is arm64, so a
  universal link fails on the x86_64 slice (see ROADMAP's Packaging task).
- **Windows installer**: for real capture, run
  `./tools/fetch_libobs_windows.ps1` once, then `flutter build windows --release`
  followed by `./tools/bundle_obs_windows.ps1 build/windows/x64/runner/Release`
  (see "Real capture mode (Windows)" above); then
  `ISCC.exe tools\windows_installer.iss` (Inno Setup) → `dist/Rewind-windows-setup.exe`.
  Skipping the fetch/bundle steps still produces a working installer, just
  with capture stubbed.
- **Windows portable zip** (no installer): after the build + bundle above,
  `Compress-Archive build/windows/x64/runner/Release dist/Rewind-windows-x64-portable.zip`
  — unzip and run `rewind.exe`. `release.yml` produces this alongside the
  installer on every tag.

## Project layout

See `CLAUDE.md` for the full map. Short version:

- `lib/` — Flutter/Dart app (UI, event watchers, coordinator, FFI bindings)
- `native/shim/` — C shim over libobs
- `tools/` — libobs fetch/bundle, icon gen, e2e smoke, **DMG + installer packaging**
- `.github/workflows/` — CI + releases

## Adding support for a new game

This is designed to be a **small, self-contained PR** — you never touch the
capture engine, the UI, or the coordinator. Pick the path that matches what
your game exposes.

> **Non-negotiable rule (read first):** you may read events only from
> **sanctioned** sources — an official local API (like League's `127.0.0.1:2999`
> Live Client Data API), official log files, or a vendor SDK. **Never** read
> game memory, inject into the game, hook it, or sniff packets. A PR that does
> is rejected on sight — it risks getting users banned. See `docs/COMPLIANCE.md`.

### Path A — the game just needs to be *detected* (most games)

If there's no per-event API, Rewind still auto-detects the game running and
lets the user hotkey-clip. You only add one row to the catalog:

1. Open `lib/src/events/game_catalog.dart` and add a `CatalogGame` to
   `popularGamesCatalog`:
   ```dart
   CatalogGame(
     gameId: 'app:valorant',          // 'app:<slug>' — must be unique
     displayName: 'VALORANT',
     processMatch: 'VALORANT-Win64-Shipping', // case-insensitive substring of
                                              // the process name (see below)
   ),
   ```
2. Find the real process name: run the game, then `ps -axo comm= | grep -i <name>`
   on macOS (or Task Manager → Details on Windows). Use a substring that's
   unique to this game.
3. **Test** in `test/game_catalog_test.dart` — the catalog already has
   invariant tests (unique ids, non-empty fields); add a `displayNameFor`
   assertion if your slug needs a friendly name.

That's the whole PR. `ProcessWatcherSource` + `buildSources` pick it up
automatically; the game appears in the rail and Supported Games.

### Path B — the game has an official event API (auto-clip highlights)

Like League: a local API that reports kills/objectives so Rewind can clip them
automatically. This is a `GameEventSource`.

1. Create `lib/src/events/<game>_event_watcher.dart` implementing
   `GameEventSource` (see `league_event_watcher.dart` as the reference). Key
   points:
   - **Inject the transport** so it's testable without a live game — take a
     `Future<String?> Function(String path)? fetch` in the constructor,
     defaulting to the real HTTP client. (League does exactly this.)
   - **Poll on a timer** in `start()`, translate new events into `GameEvent`s
     on a broadcast `StreamController`, and be robust to the API being
     down between/around matches (connection-refused is normal — never throw).
   - Map raw events to `GameEventKind` (add a new kind to
     `lib/src/events/game_event.dart` if yours isn't covered, and give it a
     `clipPriority` + an `eventColor` case).
2. Register it in `lib/src/events/source_builder.dart` (`buildSources` — add it
   to the initial `sources` list, like `LeagueEventWatcher()`).
3. **Test** in `test/<game>_event_watcher_test.dart`, driving the injected
   `fetch` with canned API bodies. Cover, at minimum:
   - it detects a running game (`isGameRunning`);
   - it emits the right `GameEventKind` for a real event payload;
   - it does **not** emit for events that aren't the active player / are
     stale / are replayed history (League's tests are a good template).

### Both paths — finishing the PR

- Add the game to the supported-games table in `README.md`.
- `dart format .` and `flutter analyze` must pass; `flutter test` green.
- Follow the PR checklist in `docs/COMPLIANCE.md` (confirm the source is
  sanctioned).

The `ClipCoordinator`, storage, thumbnails, match cards, and UI all handle the
rest — you never touch them.

## Conventions

- **Dart:** `dart format .` and `flutter analyze` must pass. Lints in `analysis_options.yaml`.
- **C:** C11, no C++ in the shim (keeps FFI binding simple).
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) — `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`. These drive changelog/release notes.
- **Docs:** update relevant docs in the same PR as the behavior change (see CLAUDE.md → "Maintaining docs").

## Tests

```bash
flutter test
```

Event watchers are pure Dart and must be unit-testable without a running game (mock the HTTP source).

## License

By contributing you agree your contributions are licensed under **GPLv3**, matching the project.
