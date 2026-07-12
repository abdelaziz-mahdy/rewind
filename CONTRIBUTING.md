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
