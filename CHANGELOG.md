# Changelog

All notable changes to Rewind are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **League of Legends match tracker**: match cards and the match detail
  screen now show a full stat line (K/D/A, creep score, ward score — polled
  live from the Live Client Data API's `playerlist[].scores`, alongside the
  existing kill/death event tracking), the player's champion portrait and
  skin name, their final item build, and each teammate's/opponent's
  champion **and in-game name** together (never as two lists that could
  drift apart) — all via a new `MatchPlayer` model with legacy-string
  backward compatibility for existing `matches.json` files. Champion/item
  art comes from Data Dragon (`DDragon`, already built); it and the new
  live-stats polling are wired through a new `GameEventKind.statsUpdate`
  event kind, kept deliberately separate from the one-shot `matchInfo`
  event since stats change every poll while champion/mode/skin don't. The
  left rail now also shows each game's real, OS-extracted app icon (cached
  via `GameConfig.iconPath`, read the same way the capture-source picker
  already reads `.icns` bundles) instead of a monogram — **except League**,
  whose app icon is Riot's official logo and stays a monogram per Riot's
  "no official logos" policy (`usesOfficialLogo`); champion/item art is
  unaffected, since Riot's policy explicitly permits game art assets.
- **Linux real-capture backend** (native shim): `xshm_input_v2`/`xcomposite_input`
  (X11 display and window/app targeting, RandR-monitor-index and XID-based)
  and a Wayland `pipewire-screen-capture-source` path (portal-driven; capture
  target selection is interactive-only there, no programmatic display/app/window
  preselection — see `native/shim/README.md`'s Linux section), PulseAudio
  audio (desktop/mic; no per-application source exists on Linux in this SDK,
  so "app audio" mode falls back to full desktop audio with a logged
  warning), and a hardware-first encoder ladder (NVIDIA NVENC → VAAPI →
  software x264) with `ffmpeg_aac` audio. New `tools/fetch_libobs_linux.sh`
  (builds libobs + this plugin set from source via CMake/Ninja against
  system X11/XCB/PipeWire/PulseAudio/FFmpeg dev packages, pinned to the same
  libobs 32.1.2 tag as macOS/Windows), wired into a new `build-linux-libobs`
  CI job (`ubuntu-latest`) that compiles `flutter build linux --debug`
  against the real fetched SDK. **Implemented and CI-compiled against the
  real pinned libobs SDK on a real Linux runner, but not yet run on any
  real Linux desktop** — no X server, Wayland compositor, or GPU driver has
  ever executed this code; see `native/shim/README.md`'s Linux section and
  `ROADMAP.md`. No `tools/bundle_obs_linux.sh` packaging script exists yet,
  and the Flutter desktop plugins Rewind depends on beyond the shim
  (`hotkey_manager`, `tray_manager`, `media_kit`, `file_selector`) each
  declare Linux support but need additional system packages/setup this
  work doesn't wire up end-to-end — a real Linux app needs more than this
  backend alone.

### Changed
- **Settings screen redesigned around real tabs** instead of one long scroll
  with a sticky jump-nav: Capture / Hotkey / Quality / Storage / About are
  now switched with tabs (default: Capture), only the selected tab's section
  is built, and the selected tab carries a bottom-indicator bar in addition
  to accent text (a non-colour cue, same reasoning as the event-matrix
  chips' check mark). Every setting in Capture/Hotkey/Quality/Storage now
  follows one row grammar (label + optional muted hint on the left, control
  sized to its own content on the right, a hairline divider between rows)
  instead of a mix of label-above-control and label-left/control-right. The
  content column is left-aligned beside the rail instead of centered in the
  window. About keeps its prose/buttons/disclaimer layout, unchanged. Purely
  a layout change — no setting's behavior, callback, or persisted value
  changed.

## [0.1.0] - 2026-07-16

First tagged release. macOS is the validated platform (real capture, League
auto-clipping); the Windows backend is implemented and CI-compiled but not
yet validated on real hardware — see ROADMAP.

### Added
- **Windows real-capture backend** (native shim): `monitor_capture`/`window_capture` (display and window/app targeting — `game_capture`'s hook-injection was deliberately avoided on anti-cheat-safety grounds, see `docs/COMPLIANCE.md`), WASAPI audio (desktop / per-app via `wasapi_process_output_capture` / mic), and a hardware-first encoder fallback ladder (NVENC → AMD AMF → Intel Quick Sync → software x264) with `ffmpeg_aac` audio. New `tools/fetch_libobs_windows.ps1` (assembles a libobs SDK from the official prebuilt Windows runtime + a matching Sources tarball, synthesizing an import lib from the DLL's export table) and `tools/bundle_obs_windows.ps1` (bundles the runtime next to a built `rewind.exe`), both wired into a new `build-windows-libobs` CI job and into `release.yml`'s Windows leg. **Implemented and CI-compiled against the real pinned libobs SDK, but not yet validated on real Windows hardware** — see `native/shim/README.md`'s Windows section and `ROADMAP.md`.
- The C shim is split per platform (`rewind_obs.c` shared API + stub, `rewind_obs_macos.c`, `rewind_obs_windows.c`) behind an `rw_plat_*` seam, so a third backend (Linux) drops in without touching the shared layer.
- Recording quality settings (Settings → Recording quality): framerate (30/60 fps), resolution (Source / 1440p / 1080p / 720p, downscaled to save CPU + disk), and a **system-audio** toggle so you can drop other apps' sound and keep voice-only clips.
- Distributable installers: `tools/package_macos_dmg.sh` builds a drag-to-Applications macOS `.dmg` (pure `hdiutil`), `tools/windows_installer.iss` builds a Windows installer (Inno Setup), and `release.yml` produces both on every `v*` tag. macOS release builds are arm64 (the fetched libobs is arm64-only).
- League match details captured per match: the champion you played, your teammates' and enemies' champions, and the game mode (Arena / ARAM / Summoner's Rift / …), read once from the Live Client API. The match card leads with "CHAMPION · MODE · age"; opening the match shows both teams' champions and the full K/D. Stored in `matches.json`.
- Game hubs show **match cards**: each play session is one card — the headline indicator is a bold **kills / deaths** scoreboard (shown over the thumbnail and in the footer, kills green / deaths red) for League, or a clip count otherwise. Tapping opens that match's clips. Deaths are tracked from the Live Client API (you as the victim) and, with kills, persisted per match in `matches.json`. (K/D is recorded going forward; matches from before this update show clip counts only.)
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
- League Live Client API never connected: Riot signs it with a self-signed certificate, which the watcher's stock HTTP client rejected — Rewind sat on "waiting for a match" through live games. Trust is now scoped to exactly 127.0.0.1:2999.
- League event storm: `eventdata` is match-global (all players) and replays the full match history on connect — a live Arena match auto-clipped every kill by anyone, 44 MB each, every ~5 seconds. The watcher now seeds past history, emits only the active player's events (`activeplayername`, failing closed), and the coordinator rate-limits event saves (10 s cooldown; manual saves exempt) and waits briefly for the mux helper to finish writing before indexing (clips silently vanished from the library during the incident).
- League hub claimed "In match — connected to 127.0.0.1:2999" when the client was merely open in the lobby (the merged row's process-detection half firing); the status line now distinguishes in-match (vendor API live) from client-open-waiting.
- Clips could be dropped on Windows when `File.length()` transiently failed (mux-writer handle contention) while waiting for a saved file to settle; the settle read now tolerates the hiccup instead of discarding the clip.
- Replay saves silently failing: the `obs-ffmpeg-mux` helper is now shipped and auto-bundled (Xcode build phase); its absence is also detected and named in errors.
- Capture recorded only the top-left quarter on Retina displays (canvas sized in points instead of physical pixels).
- Screen-recording permission churn: the app is signed with a stable identity so macOS grants survive rebuilds, and the shim asks TCC directly (`CGPreflightScreenCaptureAccess`) so permission errors are precise; the permission hint only shows for actual permission failures.


[Unreleased]: https://github.com/abdelaziz-mahdy/rewind/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/abdelaziz-mahdy/rewind/releases/tag/v0.1.0
