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

## Project layout

See `CLAUDE.md` for the full map. Short version:

- `lib/` — Flutter/Dart app (UI, event watchers, coordinator, FFI bindings)
- `native/shim/` — C shim over libobs
- `.github/workflows/` — CI + releases

## Adding a new game integration (the extensible path)

You should **not** need to touch the capture engine. To add a game:

1. Create `lib/src/events/<game>_event_watcher.dart` implementing `GameEventSource`.
2. Emit `GameEvent`s on its stream when notable things happen.
3. Register it in `lib/src/events/game_registry.dart`.
4. Add the game to the supported-games table in `README.md`.
5. Add a test under `test/`.

That's it — the `ClipCoordinator` and capture engine handle the rest.

**Legal / anti-cheat rule (mandatory):** an integration may read events only
from *sanctioned* sources — official local APIs (e.g. League's `2999` API),
official logs, or vendor SDKs — or fall back to manual-hotkey capture. Never
read game memory, inject, hook, or capture packets. See `docs/COMPLIANCE.md` and
its PR checklist.

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
