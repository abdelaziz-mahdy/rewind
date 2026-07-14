# CLAUDE.md

Guidance for Claude (and other AI assistants) working in the Rewind repository. Read this first before making changes.

## What Rewind is

Rewind is an open-source, cross-platform (Windows + macOS) instant-replay and automatic game-clip capture app. It is the ShadowPlay / Medal.tv experience for macOS as well as Windows, in one codebase.

- **UI + app logic:** Flutter / Dart
- **Capture engine:** embedded **libobs** (the OBS Studio core), driven through a small **C shim** in `native/shim/`, called from Dart via `dart:ffi`. The shim is compiled & bundled automatically by a Dart **build hook** (`hook/build.dart`) as a code asset — no per-OS build files.
- **Event detection:** per-game watchers in Dart (first target: League of Legends Live Client Data API on `127.0.0.1:2999`)
- **License:** GPLv3 (mandatory — libobs is GPL)

## Repository layout

```
rewind/
├── README.md            Project overview
├── CLAUDE.md            This file
├── ROADMAP.md           Milestones and versioned plan
├── ARCHITECTURE.md      Detailed technical design
├── CONTRIBUTING.md      Build + contribution guide
├── CHANGELOG.md         Keep a Changelog format
├── LICENSE              GPLv3
├── pubspec.yaml         Flutter/Dart package manifest
├── lib/
│   ├── main.dart        App entry point
│   └── src/
│       ├── events/      Game event watchers, process detection, games catalog
│       ├── obs/         CaptureEngine seam + Dart FFI bindings to the C shim
│       ├── clip/        Clip model + persistent library
│       ├── coordinator/ ClipCoordinator (events/hotkey → capture engine)
│       ├── hotkey/      Global hotkey service + press-to-record capture
│       ├── tray/        Menu-bar/tray service
│       ├── log/         App-wide talker logger
│       ├── settings/    Per-game config + app settings + persistence
│       └── ui/          Shell/rail/game hubs/player (see redesign spec)
├── hook/
│   └── build.dart       Build hook: compiles + links the C shim (libobs when fetched)
├── tools/               fetch_libobs.sh, bundle_obs_macos.sh, e2e_smoke.sh, icon gens
├── native/
│   ├── shim/            C shim over libobs (rewind_obs.h/.c, dual stub/real mode)
│   └── third_party/     git-ignored: fetched libobs SDK + build scratch
├── test/                Dart tests
├── docs/                Extra documentation
└── .github/workflows/   CI + release automation
```

## Core principles

1. **Keep the C surface tiny.** All libobs interaction lives behind the C shim in `native/shim/`. The shim exposes a handful of stable C functions (`rewind_obs_init`, `rewind_start_buffer`, `rewind_save_clip`, `rewind_stop`, `rewind_obs_shutdown`). Dart never touches libobs directly. Growing this API surface should be deliberate.
2. **Platform-specific code stays native and thin.** Capture source selection (screen capture kit on macOS, Windows Graphics Capture on Windows) is configured inside the shim/libobs, not scattered through Dart.
3. **Event watchers are pure Dart and testable.** They poll/subscribe to a local source and emit `GameEvent`s. They must not depend on the capture engine — they emit events; a coordinator decides whether to save a clip.
4. **Everything cross-platform by default.** If something can only work on one OS, isolate it and provide a no-op/fallback on the other.
5. **Sanctioned sources only (legal/anti-cheat).** Integrations may read only official local APIs, logs, or SDKs — NEVER game memory, injection, hooking, or packet capture. No sanctioned source → manual-hotkey capture only. See `docs/COMPLIANCE.md`. This is non-negotiable; it protects users' accounts.

## Working on this app — hard-won knowledge (read before debugging capture or UI)

**Scripts you must know:**
- `tools/fetch_libobs.sh` — builds the pinned libobs SDK once into git-ignored
  `native/third_party/obs/` (~2 min, cached by a stamp). Without it the shim
  builds in **stub mode** (app runs, saves write no file). Bump pins inside
  the script only; the CI cache key must match.
- `tools/bundle_obs_macos.sh` — bundles the libobs runtime into a built .app.
  You almost never run it by hand: an Xcode "Bundle libobs runtime" build
  phase runs it on every `flutter build macos` when the SDK exists.
- `tools/e2e_smoke.sh` — THE canonical end-to-end check: launches the real
  app, saves a clip headlessly, fails on missing helper / permission problems
  / short clips / **black frames**. Run it after anything touching capture.
- Debug save trigger: `touch ~/Movies/Rewind/.save-now` acts like the hotkey
  (debug builds only) — how agents save clips without a keyboard.

**macOS capture gotchas (each cost hours once):**
- **TCC / Screen Recording keys off the code signature.** The app signs with
  a real Apple Development identity (set in the Xcode project) so grants
  survive rebuilds. Never revert to ad-hoc `-s -`. If permission breaks:
  `tccutil reset ScreenCapture com.example.rewind`, launch via `open`,
  re-grant once.
- **Launch context matters:** running the binary from a terminal attributes
  screen capture to the TERMINAL. Always test via
  `open build/macos/Build/Products/Debug/rewind.app`.
- **`open` silently reuses a running instance** — `pkill -x rewind` first,
  then verify the process start time postdates the binary mtime.
- **A sleeping display records legitimate black frames** (the e2e script
  runs `caffeinate` for this reason). Retina canvases must use PHYSICAL
  pixels (`CGDisplayModeGetPixelWidth`), not points — points capture only
  the top-left quarter.
- **`obs-ffmpeg-mux` is a separate helper executable** spawned from next to
  the main binary; if missing, every save fails with "Failed to create
  process pipe". The fetch script ships it; the bundle phase places it.
- mac-capture source settings: `type` (0 display / 2 application),
  `display_uuid` (ALWAYS required, even for app capture), `application`
  (bundle id). Verified against the vendored source in
  `native/third_party/work/obs-studio/plugins/mac-capture/`.

**UI layer rules (post game-centric redesign — spec:
`docs/superpowers/specs/2026-07-13-game-centric-redesign.md`):**
- All styling flows through `RewindTokens` / the text-theme extension in
  `lib/src/ui/theme.dart`. NO glow/BoxShadow, no gradients, no pill radii
  (`circular(999)`), no raw hex in widgets. Hover/press overlays must
  LIGHTEN (low-alpha white) — dark-on-dark overlays are invisible.
- Navigation: `shell.dart` (rail + recorder deck + destinations) on a sealed
  `shell_destination.dart` value. No router/state-management packages.
- Beware Flutter's flex-allocation trap: several loose `Flexible(flex: 1)`
  children + a `Spacer` in one Row each get an equal SHARE of free space
  whether used or not — trailing buttons end up stranded mid-row. One
  `Expanded` filler per row.

**Testing gotchas:**
- Never pipe `flutter test` through `tail`/`grep` when the exit code matters
  — pipes mask failures. Redirect to a file and `echo $?`.
- `pumpAndSettle` NEVER settles on screens containing the recorder deck (the
  REC dot animates forever) — use bounded `pump(Duration(...))`.
- `PlayerScreen` cannot be built in widget tests (media_kit needs native
  libmpv); tests assert navigation by route name (`playerScreenRouteName`).
- Real `dart:io` file work inside `testWidgets` bodies hangs the fake-async
  zone — use plain `test()` or fakes.
- Tall screens need `t.view.physicalSize` widening or off-screen widgets
  never build.

## Conventions

- Dart: follow `flutter analyze` / `dart format`. Lints in `analysis_options.yaml`.
- C: C11, no C++ in the shim (keeps `dart:ffi` binding simple — no name mangling).
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`). This drives the changelog and release notes.
- Versioning: Semantic Versioning. Pre-1.0 the minor version tracks roadmap milestones.

## Maintaining docs (important)

When you change behavior, **update the docs in the same change**:

- New feature / milestone reached → update `ROADMAP.md` and `CHANGELOG.md`.
- Architecture or data-flow change → update `ARCHITECTURE.md` (and the diagram in `README.md` if the layering changes).
- New build step or dependency → update `CONTRIBUTING.md`.
- New game integration → update the supported-games table in `README.md`.

Do not let README/ROADMAP/ARCHITECTURE drift from the code. A PR that changes behavior without touching docs is incomplete.

## Releases

Releases are tag-driven. Pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds macOS and Windows artifacts and drafts a GitHub Release. Before tagging: bump the version in `pubspec.yaml`, move the `CHANGELOG.md` "Unreleased" section into a dated version heading. See ROADMAP for the release checklist.

## Things to be careful about

- **GPLv3 is load-bearing.** Because libobs is embedded, the whole app must remain GPLv3. Do not add code under an incompatible license, and do not suggest a closed-source distribution model.
- **libobs runtime data.** libobs needs its plugins/data files shipped alongside the binary. Packaging must bundle these — see ARCHITECTURE.md.
- **The 2999 API only exists mid-game.** League's Live Client Data API is only up while a match is running; watchers must handle connection-refused gracefully and back off.
