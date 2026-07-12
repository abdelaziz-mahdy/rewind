# Roadmap

Rewind is built in small, shippable milestones. Each milestone ends in a tagged release. Versioning is SemVer; pre-1.0 the minor version tracks the milestone.

## Guiding requirements

These shape every milestone:

- **Cross-platform:** Windows + macOS from day one.
- **Extensible by design:** adding a new game must not require touching the capture engine or core app — only adding a new `GameEventSource` and registering it. See ARCHITECTURE.md → "Game integration plugins".
- **Cross-game:** multiple game integrations can be active; Rewind detects which game is running and attaches the right watcher. A generic manual-hotkey path works for *any* game (or the desktop) with no integration.
- **Storage-aware:** a rolling clip library that respects a user disk budget — automatically prunes the oldest clips when over quota, but **never deletes protected/pinned clips**.
- **Legal / anti-cheat safe:** integrations use only sanctioned sources (official APIs/logs/SDKs) or screen capture — never memory/injection/hooking. See `docs/COMPLIANCE.md`.

## v0.1 — "It records" (foundation)

- [x] Flutter desktop shell (macOS + Windows), tray/menu-bar presence
- [x] C shim over libobs: init, start buffer, save clip, set-buffer-length, stop, shutdown (real libobs on macOS via `tools/fetch_libobs.sh`; stub elsewhere)
- [x] **Native build hook (`hook/build.dart`)** compiles + bundles the shim automatically
- [x] Dart `@Native` FFI bindings to the shim
- [x] Manual global **hotkey → save last N seconds** (30s / 60s / custom)
- [x] **Per-game buffer length** setting (30s vs 60s etc. per game)
- [x] Basic clip library view
- [x] CI builds on both platforms

> Windows real capture (Windows Graphics Capture source + encoder wiring in
> the shim) is deferred to a follow-up: the app builds and tests on Windows in
> stub mode, and needs a Windows machine/tester for the native bring-up.

## v0.2 — "It clips League automatically" (first integration)

- [ ] `GameEventSource` abstraction + `GameRegistry`
- [ ] `LeagueEventWatcher` (Live Client Data API @ `127.0.0.1:2999`)
- [ ] `ClipCoordinator`: event → save clip, tagged by event type
- [ ] Per-event enable/disable settings (kills, multikills, aces, dragon/baron, turrets)
- [ ] **Game auto-detection**: supervisor detects the running game and applies its per-game config automatically
- [ ] Second test target (mech action game) in manual-hotkey mode; validate cross-game switching

## v0.3 — "It manages storage" (storage-aware)

- [ ] `StorageManager`: configurable disk budget + retention policy
- [ ] Auto-prune oldest clips when over budget
- [ ] **Pin / protect** clips so they're exempt from pruning
- [ ] Retention rules (e.g. keep last N days, keep all pinned, keep per-event caps)
- [ ] Library UI: pin toggle, storage usage meter, manual delete

## v0.4 — "It's extensible" (more games)

- [ ] Documented integration API + template for adding a game
- [ ] Second and third game integrations (candidates: any title exposing a local API or log; generic OBS-style scene detection as fallback)
- [ ] Optional community-contributed integrations folder

## v0.5 — "It's shareable"

- [ ] In-app trim/clip editor
- [ ] Export presets (resolution/bitrate)
- [ ] Optional upload/share targets

## v1.0 — "It's polished"

- [ ] Signed + notarized macOS build, signed Windows installer
- [ ] Auto-update
- [ ] Stable public integration API

## Release checklist (every tagged release)

1. Bump `version` in `pubspec.yaml`.
2. Move `CHANGELOG.md` "Unreleased" entries under a dated `## [x.y.z]` heading.
3. Ensure docs (README/ROADMAP/ARCHITECTURE) match reality.
4. Tag `vX.Y.Z` and push → `release.yml` builds artifacts + drafts the GitHub Release.
5. Review the draft release notes, attach binaries, publish.
