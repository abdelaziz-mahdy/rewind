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
│       ├── events/      Game event watchers + models
│       ├── obs/         Dart FFI bindings to the C shim
│       ├── clip/        Clip model + library
│       ├── settings/    Per-game config + app settings
│       └── ui/          Flutter widgets/screens
├── hook/
│   └── build.dart       Build hook: compiles + bundles the C shim
├── native/
│   └── shim/            C shim over libobs (rewind_obs.h/.c)
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
