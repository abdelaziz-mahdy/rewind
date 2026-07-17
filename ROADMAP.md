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
- [x] C shim over libobs: init, start buffer, save clip, set-buffer-length, stop, shutdown (real libobs on macOS via `tools/fetch_libobs.sh` and on Windows via `tools/fetch_libobs_windows.ps1`, both unsigned/CI-compiled — Windows unvalidated on hardware, see note below; stub when the SDK isn't fetched)
- [x] **Native build hook (`hook/build.dart`)** compiles + bundles the shim automatically
- [x] Dart `@Native` FFI bindings to the shim
- [x] Manual global **hotkey → save last N seconds** (30s / 60s / custom)
- [x] **Per-game buffer length** setting (30s vs 60s etc. per game)
- [x] Basic clip library view
- [x] CI builds on both platforms

> Windows real capture (monitor/window capture + WASAPI audio + NVENC/AMF/QSV/
> x264 encoder ladder in the shim — see `native/shim/README.md`'s Windows
> section) is implemented and wired into CI (`build-windows-libobs` in
> `ci.yml` compiles it against the real pinned libobs SDK), but is
> **unvalidated on real Windows hardware** — it was written and CI-compiled
> without a Windows machine or GPU to run it on. Needs a Windows tester to
> confirm actual capture/encode/save before this checkbox is trustworthy;
> see `docs/COMPLIANCE.md` and the shim README for what to verify first.

> **Linux real capture** (X11 `xshm_input_v2`/`xcomposite_input` display and
> window capture, Wayland portal-backed capture via `linux-pipewire`,
> PulseAudio audio, VAAPI/NVENC/x264 encoder ladder in the shim — see
> `native/shim/README.md`'s Linux section) is implemented and wired into CI
> (`build-linux-libobs` in `ci.yml` compiles it on a real Ubuntu runner
> against the real pinned libobs SDK), but is **unvalidated on any real
> Linux desktop** — no X server, no Wayland compositor, no GPU driver has
> ever run this code. There is also **no distributable Linux build yet**:
> no `tools/bundle_obs_linux.sh` packaging script, and the Flutter desktop
> plugins Rewind depends on for hotkeys/tray/playback (`hotkey_manager`,
> `tray_manager`, `media_kit`, `file_selector`) each declare Linux support
> but need system packages this repo doesn't yet document/install
> end-to-end (`keybinder-3.0`, `libayatana-appindicator3`, `libmpv`) and
> `tray_manager` specifically won't show an icon on stock GNOME without the
> user installing a Shell extension. A real Linux app needs all of the
> above, not just the shim. See `native/shim/README.md` and
> `ARCHITECTURE.md`'s Packaging section.

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
- [x] **Windows installer + portable zip**: `tools/windows_installer.iss`
      (Inno Setup) packages the Windows build (now including the bundled
      libobs runtime — `tools/fetch_libobs_windows.ps1` +
      `tools/bundle_obs_windows.ps1`, see `release.yml`) into
      `Rewind-windows-setup.exe`; the same bundled app is also zipped to
      `Rewind-windows-x64-portable.zip` (unzip and run `rewind.exe`, no
      install) for a no-installer try.
- [x] **`release.yml`**: on a `v*` tag — fetch libobs (both platforms), build
      release, bundle, package DMG (macOS, arm64) + installer (Windows),
      attach both to the drafted GitHub Release.
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
