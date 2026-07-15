# Changelog

All notable changes to Rewind are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- League Live Client API never connected: Riot signs it with a self-signed certificate, which the watcher's stock HTTP client rejected — Rewind sat on "waiting for a match" through live games. Trust is now scoped to exactly 127.0.0.1:2999.
- League event storm: `eventdata` is match-global (all players) and replays the full match history on connect — a live Arena match auto-clipped every kill by anyone, 44 MB each, every ~5 seconds. The watcher now seeds past history, emits only the active player's events (`activeplayername`, failing closed), and the coordinator rate-limits event saves (10 s cooldown; manual saves exempt) and waits briefly for the mux helper to finish writing before indexing (clips silently vanished from the library during the incident).
- League hub claimed "In match — connected to 127.0.0.1:2999" when the client was merely open in the lobby (the merged row's process-detection half firing); the status line now distinguishes in-match (vendor API live) from client-open-waiting.

### Added
- Audio in clips at last: clips had a silent AAC track (no audio source was attached) — system/game audio is now always captured (`sck_audio_capture`), and a new **Capture microphone** toggle (Settings → Capture, default off, applies live) mixes your mic in (`coreaudio_input_capture`; macOS prompts for mic permission on first enable).
- Kill counts on clips: each saved clip/recording is stamped with how many of YOUR kills its footage covers (`Clip.killCount`, from the live event stream) and tiles show "· N kills".
- All Clips grouped by game: sections with avatar + name + count headers, newest game first (League's two gameIds merge into one section, same as the rail).
- Clips grouped by match: game hubs section their clip grids into play sessions — the coordinator stamps each clip with its game's activation time (`Clip.sessionAt`), so one match = one group, headed "MATCH · 2 H AGO · 3 CLIPS" ("SESSION" for games without an in-match API); pre-existing clips fall back to 30-minute time-gap clustering.
- Storage settings + auto-cleanup controls: a new Settings → Storage section with live usage ("31 clips · 1.2 GB"), a max-storage cap in GB (blank = unlimited; default 20 GB — previously hardcoded), delete-clips-older-than-N-days (blank = never), and a "Recordings folder" picker (native folder dialog via `file_selector`; applies on next launch, falls back loudly to the per-OS default if the chosen folder becomes unusable). Cleanup runs at startup, every 30 minutes, after every save, and immediately when limits are tightened.
- Protect clips from auto-cleanup: a clip tile's overflow menu can pin a clip ("Protect from auto-cleanup"); protected clips show a small lock in their footer and are never touched by size/age pruning.
- Orphaned-thumbnail sweep at startup: `.thumbs/` images whose clip was deleted outside the app (e.g. in Finder) are removed.
- CrossOver/Wine game support: Windows games running under a translation layer (CrossOver, Wine, Whisky) now appear in the capture-source picker under their real exe name (e.g. "PenguinHotel-Win64-Shipping") instead of being invisible or collapsed into a single "CrossOver" entry; picking one registers it as a game (detection, rail hub, clip filing) and captures the game's WINDOW (`rewind_set_capture_window`, ScreenCaptureKit window stream) — macOS gives Wine processes no bundle id for app capture, and plain display capture leaked whatever shared the screen (Discord etc.) into clips. Auto-switch targets the window too. Picked-app names survive everywhere: `GameConfig.displayName` keeps the real casing in the rail/hub/clips, and `AppSettings.captureAppName` keeps the source label unambiguous.
- Capture-source menu v2: grouped into DISPLAYS / DETECTED GAMES / APPLICATIONS, each app row shows its real icon (extracted from the bundle's `.icns` — a minimal PNG-entry reader, no native image framework) with a monogram fallback for Wine games; menu-bar/agent noise (Dock, Control Center, Notification Center) is filtered out of the enumeration (normal-layer ≥64 px windows only).
- Live refresh while running: the capture-source menu re-enumerates running apps every time it opens (a game launched after Rewind now shows up), and a game added mid-session (picked app or Supported Games' Add) gets its detection watcher immediately (`GameRegistry.addNewSources`) — no restart needed for either.
- Capture-source picker moved to the top of the recorder cluster (source → actions) and restyled as a bordered control with a chevron so it reads as tappable.
- Clip thumbnails: clip tiles show a real video frame (generated headlessly via media_kit, cached as `.thumbs/<clip>.jpg` beside each clip) instead of a static play-glyph placeholder; generated automatically after every new save and backfilled in the background on startup for pre-existing clips; deleted alongside the clip.
- Manual recording: a deck "Record" button (with a live elapsed readout) and a dedicated global hotkey (default Alt+F9, independently rebindable in Settings) start/stop a continuous recording session — separate from the rolling replay buffer, both can run at once — saved as a `recording`-tagged clip; the tray gets a matching "Start/Stop recording" item. `HotkeyService.bindAll` now registers the save and record hotkeys independently.
- Game-centric UI redesign: a persistent left rail (your games + All Clips + Supported Games) replaces the old home-screen filter rail; each game gets its own hub (integration status, inline per-game capture settings, scoped clips, a v0.2 live-events feed slot); a new **Supported Games** screen lists every auto-detectable title with its live/library state and an Add flow; Settings is slimmed to global Capture/Hotkey (per-game settings moved into each hub) and embedded as a rail destination, with a new "Follow the game" (`autoSwitchCapture`) toggle. Sharp rectangular visual language (`RewindTokens`), no more pill shapes or glow.
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

### Fixed
- Replay saves silently failing: the `obs-ffmpeg-mux` helper is now shipped and auto-bundled (Xcode build phase); its absence is also detected and named in errors.
- Capture recorded only the top-left quarter on Retina displays (canvas sized in points instead of physical pixels).
- Screen-recording permission churn: the app is signed with a stable identity so macOS grants survive rebuilds, and the shim asks TCC directly (`CGPreflightScreenCaptureAccess`) so permission errors are precise; the permission hint only shows for actual permission failures.


[Unreleased]: https://example.com/rewind/compare/main...HEAD
