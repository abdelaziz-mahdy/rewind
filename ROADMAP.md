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

> The game-centric UI redesign (see CHANGELOG "Unreleased") already has a slot
> waiting for this: the League hub's integration card renders a "LIVE EVENTS"
> feed of the last ~20 `GameEvent`s the moment the watcher above starts
> emitting them (`game_hub_screen.dart`) — no further UI work needed once the
> watcher lands.

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

## Packaging & CI/CD — distributable installers

Turn the tag-driven release into real, downloadable installers.

- [x] **macOS `.dmg`**: `tools/package_macos_dmg.sh` packages the built
      `.app` (bundled libobs runtime + `obs-ffmpeg-mux` helper) into a
      drag-to-Applications DMG with pure `hdiutil` — no `appdmg`/Node
      dependency. Validated locally.
- [x] **Windows installer**: `tools/windows_installer.iss` (Inno Setup)
      packages the Windows build into `Rewind-windows-setup.exe`.
- [x] **`release.yml`**: on a `v*` tag — fetch libobs, build release,
      bundle, package DMG (macOS, arm64) + installer (Windows), attach both
      to the drafted GitHub Release.
- [x] **arm64 release builds**: `flutter build macos --release` links only
      arm64 via `FLUTTER_XCODE_ARCHS=arm64` +
      `FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES` (the fetched libobs is arm64-only,
      so a universal link fails on the x86_64 slice).
- [x] **CI code-signing workaround**: the Xcode project pins a local Apple
      Development identity (team `YBLFC373J5`) so Screen-Recording (TCC)
      grants survive dev rebuilds. CI runners don't have that certificate, so
      the macOS build/release jobs pass `FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO`
      and rely on the mandatory arm64 **ad-hoc** signature (the bundle step
      formalizes it). Result: CI ships **unsigned/ad-hoc** artifacts
      (right-click → Open on first run). Proper fix — a CI secret holding a
      real Developer ID cert + notarization — is the v1.0 signing item below.
- [ ] **Universal / x86_64 macOS build** (follow-up): build a universal
      libobs in `tools/fetch_libobs.sh` (or ship a separate x86_64 DMG) so
      Intel Macs are covered. Currently arm64-only.
- [ ] Signing/notarization + a signed Windows installer are the v1.0 items
      below; the CI currently ships unsigned artifacts (right-click → Open
      on macOS first run).

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
