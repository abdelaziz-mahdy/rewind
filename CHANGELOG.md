# Changelog

All notable changes to Rewind are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Real screen capture on macOS: the C shim drives libobs 32.1.2 (ScreenCaptureKit display capture, VideoToolbox H.264 + CoreAudio AAC encoders, replay-buffer output) when the SDK built by `tools/fetch_libobs.sh` is present; self-contained stub otherwise.
- `tools/fetch_libobs.sh`: pinned, cached, minimal libobs SDK build (libobs + mac-capture, obs-ffmpeg, coreaudio-encoder, mac-videotoolbox).
- `tools/bundle_obs_macos.sh`: bundles the libobs runtime (frameworks, plugins, data) into the built macOS app and ad-hoc re-signs it.
- `CaptureEngine` seam between the coordinator and the FFI layer; all Dart logic is testable against a fake with no native library.
- Settings persistence (`SettingsStore` → settings.json) with corrupt-file recovery; clip metadata persistence (`clips.json`) with disk reconciliation.
- Global "clip that" hotkey (default Alt+F10) via portable descriptor parsing; rebindable in Settings.
- Tray / menu-bar presence: save clip, pause/resume buffer, quit.
- Gamer-dark UI: status strip (buffer state, active game, save button, capture-error banner), clip library (event badges, reveal/delete/open), settings screen (hotkey, default + per-game buffer length).
- Per-OS clips directory (`~/Movies/Rewind` on macOS, `Videos\Rewind` on Windows).
- CI: macOS build against real libobs with cached SDK; `flutter test` on Windows.
- Native build hook (`hook/build.dart`) that compiles and bundles the C shim as a code asset; `@Native` FFI bindings.
- `rewind_set_buffer_seconds` shim call for per-game replay-buffer length.
- Per-game configuration (`GameConfig`/`AppSettings`): configurable buffer length (30s/60s/custom), enabled events, and hotkey — per game.
- Game auto-detection: `GameRegistry` publishes active-game transitions; coordinator applies the active game's config automatically.
- `docs/COMPLIANCE.md`: legal / anti-cheat policy (sanctioned sources only; manual-hotkey fallback).
- Initial repository scaffold: docs (README, CLAUDE.md, ARCHITECTURE, ROADMAP, CONTRIBUTING), GPLv3 license.
- Flutter app skeleton with entry point and app shell.
- `GameEvent` model and `GameEventSource` abstraction for extensible game integrations.
- `LeagueEventWatcher` stub (League Live Client Data API @ 127.0.0.1:2999).
- `GameRegistry` for registering/auto-selecting game integrations.
- `Clip` model, `ClipLibrary`, and `StorageManager` (storage-aware retention with pin/protect).
- `ClipCoordinator` wiring events + hotkey to the capture engine.
- C shim (`native/shim/rewind_obs.h/.c`) over libobs with Dart FFI bindings stub.
- CI and tag-driven release GitHub Actions workflows.

[Unreleased]: https://example.com/rewind/compare/main...HEAD
