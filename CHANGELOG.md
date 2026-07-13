# Changelog

All notable changes to Rewind are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Home-first controls: a tappable "Capturing: …" source chip on the status card (switch display/app in one tap), tappable buffer-length readout (15/30/60/Custom), open-clips-folder buttons (Home + tray), a one-click "Open Screen Recording Settings" button on permission errors, and real game names everywhere (no raw ids).
- Auto-follow capture: when a detected game starts, capture switches to it automatically and reverts to your saved source when it exits (the chip shows "(auto)" while following; `autoSwitchCapture` setting, default on).
- Capture a specific application: "Capture application" picker in Settings (enumerated from apps with on-screen windows via CoreGraphics); reverting to "Entire display" restores display capture. Per-app targeting is a persistent preference.
- Capture display picker (multi-monitor) with stale-monitor fallback to the main display.
- Per-app auto-detection: a sanctioned process-list watcher (`ProcessWatcherSource`) plus a popular-games catalog (League, CS2, Dota 2, Valorant, Fortnite, and more) so Rewind notices known games launching; user-configured per-app entries are supported via `GameConfig.processMatch`.
- Press-to-record hotkey field: click, press the combo, done — the live hotkey is suspended while recording so it can be re-recorded safely.
- In-app clip playback (`PlayerScreen`, media_kit): tapping a clip plays it inside the app (play/pause, seek bar, elapsed/total time) instead of always launching the OS default player; "Open in default player" remains available from the clip tile's overflow menu.
- Clip library grouped per app/game with a filter-chip rail (counts per app, hidden when only one source exists).
- In-app Logs screen (talker) and save-failure snackbars — failures are never silent.
- Modern app icon (macOS + Windows, generated programmatically) and a proper Windows tray `.ico`.
- `tools/e2e_smoke.sh`: end-to-end capture test — launches the real app, saves headlessly via a debug file trigger, and fails on missing helper, permission problems, short clips, or black frames (wakes the display first).

### Fixed
- Replay saves silently failing: the `obs-ffmpeg-mux` helper is now shipped and auto-bundled (Xcode build phase); its absence is also detected and named in errors.
- Capture recorded only the top-left quarter on Retina displays (canvas sized in points instead of physical pixels).
- Screen-recording permission churn: the app is signed with a stable identity so macOS grants survive rebuilds, and the shim asks TCC directly (`CGPreflightScreenCaptureAccess`) so permission errors are precise; the permission hint only shows for actual permission failures.
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
