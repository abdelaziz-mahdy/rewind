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
- Debug record trigger: `touch ~/Movies/Rewind/.record-toggle` acts like the
  record hotkey (debug builds only) — starts/stops a manual recording.

**macOS capture gotchas (each cost hours once):**
- **TCC / Screen Recording keys off the code signature.** The app signs with
  a real Apple Development identity (set in the Xcode project) so grants
  survive rebuilds. Never revert to ad-hoc `-s -`. If permission breaks:
  `tccutil reset ScreenCapture com.zcreations.rewind`, launch via `open`,
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
- **CrossOver/Wine games have NO bundle id** — SCK application capture can
  never target them. Verified live (2026-07-14): `proc_pidpath()` for a
  Wine pid fails or returns a deleted `winetemp-*` stub (no `.app`
  ancestor), and `NSRunningApplication.bundleIdentifier` is nil. What DOES
  survive is the Windows exe name: Wine writes it to both the process comm
  (`ps -axo comm=` shows `C:\...\Game.exe`, so process detection works
  unmodified) and `kCGWindowOwnerName`. The shim names `*.exe`-owned
  windows after the exe and emits them with an EMPTY bundle id; Dart
  treats `AppInfo.bundleId == ''` as "capture the display instead" (picker
  and auto-switch revert to display — never pass `''` to `setCaptureApp`).
- **An app's representative window must be its BEST one, not its first.**
  `rw_plat_list_capturable_apps_json` emits ONE window per app (its
  `window_id`, what window-capture targets). A CrossOver/Wine game has small
  OFF-screen helper windows (a 500×500 splash, thin title bars) alongside
  its real game surface, and `CGWindowListCopyWindowInfo`'s front-to-back
  order is NOT reliably the game window — the helper can precede it. Emitting
  the first window captured a dead off-screen window → BLACK clips (verified
  live 2026-07-21, R.E.P.O.: helper `17468` 500×500 off-screen beat the
  layer-26 full-display game window `17481`; output was 1680×1050 of empty
  content). Fix: pick the display-covering window (`rw_rect_covers_a_display`)
  per app, then largest area. A black clip whose dimensions match neither the
  display nor the intended window is the signature of this bug.

**Windows packaging gotchas:**
- **A Windows DLL exports NOTHING by default.** ELF and Mach-O export every
  non-static symbol, so the shim worked on macOS/Linux while
  `rewind_obs.dll` shipped an empty export table — every `@Native` call
  failed with "Failed to lookup symbol '<name>' (error code 127)", thrown
  out of `main()` on the first `listDisplays()`. `rewind_obs.h` declares
  `REWIND_API` (`__declspec(dllexport)` on Windows, default visibility
  elsewhere) on every function; new C surface must carry it too.
- **A Windows build that runs everywhere in CI can still fail to start for
  every user.** Every binary in the bundle (runner, plugin DLLs, libobs and
  its plugins) imports the Visual C++ runtime — `MSVCP140.dll`,
  `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`. It ships with Visual Studio, so
  build machines and GitHub runners always have it and a clean Windows never
  does. The loader resolves imports BEFORE any code runs, so the process
  dies with `0xc0000135` and there is NO log file at all —
  `startFileLogging` is Dart, and Dart never started. `windows/CMakeLists.txt`
  now installs `CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS` beside `rewind.exe`.
- **"No log file" is itself the diagnostic.** Logs live in
  `%APPDATA%\zcreations\rewind\logs\` (path_provider = `%APPDATA%\<CompanyName>\<ProductName>`
  from `windows/runner/Runner.rc`). A crash WITH logs is a Dart/engine
  problem; a crash with NO logs is a loader/native problem — look at imports
  first, not at Dart.
- **The Windows app picker must INCLUDE minimized windows.** libobs'
  `check_window_valid()` only applies its iconic/cloaked/empty-rect checks in
  `EXCLUDE_MINIMIZED` mode — OBS's own dropdown lists minimized windows and
  lets capture-time matching skip them. Rewind's picker copied the strict
  form and so hid every alt-tabbed game, which is exactly the state a game is
  in while the user is choosing it. Minimized entries report
  `on_screen: false`, which `ClipCoordinator` already reads: it binds those
  by executable token instead of by an HWND with nothing to show. A
  minimized window's client rect is 0x0, so the empty-rect check has to be
  skipped for them or the change is a no-op. Cloaked windows stay excluded —
  suspended UWP frames and other-virtual-desktop windows report "visible"
  with nothing behind them.
- **libobs returns a PLACEHOLDER for an unknown encoder/source id, not
  NULL.** `obs_video_encoder_create("nope", ...)` logs "Encoder ID 'nope'
  not found" and hands back a non-NULL dummy (`libobs/obs-encoder.c`, the
  `if (!ei)` branch). Any "try each candidate, keep the first that works"
  ladder therefore always stops on its first rung — which is how every
  non-NVIDIA machine got a dummy NVENC encoder and a replay buffer that
  would not start, with NVIDIA dev machines hiding it. Probe with
  `obs_get_encoder_codec(id) != NULL` BEFORE creating. The giveaway in a log
  is an error and a success one line apart:
  `Encoder ID 'obs_nvenc_h264_tex' not found` followed by
  `rewind: using video encoder "obs_nvenc_h264_tex"`.
- **`%module%` in an `obs_add_module_path` BIN path means "directories".**
  libobs' `find_modules_in_path` truncates the path at `%module%`, then
  globs `*` and keeps only entries where `is_directory == search_directories`
  — it appends the platform extension ONLY when the token is absent. So
  Windows must pass the bare `obs-plugins/64bit` and Linux the bare
  `obs-plugins` (flat `.dll`/`.so` FILES), while macOS keeps
  `%module%.plugin/Contents/MacOS` because its plugins really are
  directories. Get it wrong and libobs starts perfectly, D3D11 initialises,
  and then EVERY source/encoder/output is "not found" — the replay buffer
  reports "failed to start" with no detail. The DATA path always keeps
  `%module%`; that one is a real substitution.
- **Windows monitor ids are device paths full of backslashes**
  (`\\?\DISPLAY#MSI4CC2#5&...`). Anything hand-built into JSON on the C
  side must go through `json_escape_append`, or `jsonDecode` throws
  "Unrecognized string escape" and the app sees an empty display list.
- **A launch check must read the log, not just find one.** `tools/launch_smoke_windows.ps1`
  greps the session log for `[exception]`, "Capture engine failed to start"
  and libobs' "ID '...' not found" lines. Without that it passed on a build
  whose capture was entirely dead — the process was alive and logging, which
  is all it used to check.
- **`data\` on Windows belongs to BOTH Flutter and libobs.** Flutter keeps
  `data\icudtl.dat`, `data\flutter_assets\` and `data\app.so` there;
  libobs wants `data\libobs\` beside them (`rw_plat_pre_video_setup` calls
  `obs_add_data_path("<exe>/data/libobs/")`). The bundle script must MERGE,
  never replace — it used to `Remove-Item -Recurse data\` first, which is
  why v0.1.0 shipped with no `flutter_assets`: the app exited during engine
  startup, before any Dart ran, on every machine. It now clears only
  `data\libobs` and `data\obs-plugins` and asserts Flutter's data survived.
- **The libobs runtime must be the LAST thing written to a run directory.**
  libobs ships `zlib.dll` and media_kit's libmpv bundle ships a DIFFERENT
  `zlib.dll` under the same name. Whichever lands last wins for BOTH.
  `bundle_obs_windows.ps1` runs after `flutter build`, so libobs wins — and
  that direction works (verified in CI: with libobs' zlib in place every one
  of 160 binaries resolves and loads, libmpv included). The other direction
  does NOT: mpv's zlib lacks exports obs.dll needs, and the whole libobs
  chain then fails to load with ERROR_PROC_NOT_FOUND (127) — obs.dll,
  libobs-d3d11, libobs-winrt, av*, rewind_obs.dll, all at once. Anything
  that re-runs Flutter's install step after bundling (notably `flutter test`
  building an integration test) puts mpv's zlib back and breaks capture, so
  Windows launch verification runs the BUILT binary
  (`tools/launch_smoke_windows.ps1`), never `flutter test`.
- **`tools/probe_load_windows.ps1` names the module the loader chokes on.**
  Static analysis of imports cannot see a loader disagreement; the probe
  LoadLibraryEx's every DLL in a bundle and prints the Win32 error per file.
  `dartjni.dll` (wants a JRE) and `graphics-hook32.dll` (OBS' 32-bit hook)
  always fail there and are expected.
- **Launch tests cannot catch a missing redistributable; the static check
  can.** `tools/check_bundle_deps.dart` parses the PE import + delay-import
  tables of every binary in a bundle and fails on anything neither bundled
  nor part of Windows, treating VC++ redist DLLs as must-be-bundled even
  when the build machine has them in System32. CI runs it on every Windows
  bundle, and `integration_test/launch_smoke_test.dart` (real `main()`, real
  device, asserts a frame + a session log) runs on both desktop platforms.

**League Live Client Data API gotchas (each verified against a live match,
2026-07-14 — see `LeagueEventWatcher` and its hermetic tests):**
- **Riot's cert is self-signed** (their own root, not in the system trust
  store). A stock HTTP client fails the TLS handshake on every request —
  the watcher looks permanently "waiting for a match" while `curl -k`
  answers fine. Trust must be scoped to exactly 127.0.0.1:2999.
- **`eventdata` is match-global**: it reports EVERY player's kills (16 in
  Arena) and returns the FULL log since match start. Unfiltered, this
  auto-clipped a 44 MB replay every ~5 s until the disk hit 99%. Always
  (a) seed past existing history on the first poll of a session, and
  (b) filter events to `/liveclientdata/activeplayername` (fail CLOSED if
  the name can't be resolved).
- The coordinator also rate-limits event saves (10 s cooldown, manual
  saves exempt) and gives the mux helper a bounded grace to finish writing
  before indexing — under save load the shim reports the path before the
  file exists, and clips silently vanish from the library without it.

**media_kit headless-Player gotchas (cost hours diagnosing thumbnail
generation — HISTORICAL since thumbnails moved to FFmpeg
(`FfmpegThumbnailGenerator`, 2026-07-20), but still true for `PlayerScreen`
playback and any future headless media_kit use):**
- **`Player.screenshot()` returns null with no VideoController attached.**
  The default headless `PlayerConfiguration` has `vo=null` (no video output),
  and mpv's `screenshot-raw` command reads from the video output's current
  frame — with no video output there's nothing to grab, so `screenshot()`
  silently resolves to `null` in well under a second (NOT a timeout). Fix: a
  `media_kit_video` `VideoController(player)` must be created (never built
  into a `Video` widget — it just needs to exist as mpv's render target),
  and `controller.waitUntilFirstFrameRendered` awaited before screenshotting.
- **Subscribe to a Player property stream BEFORE calling `open()`.**
  `PlayerStream.duration` (and friends) is a broadcast `StreamController`;
  mpv's property observers are registered at `Player()` construction, so the
  "duration known" event can fire as early as during `open()` itself. A
  `.firstWhere()` subscription started only after `await player.open(...)`
  can miss that event entirely — broadcast streams never replay past events
  — hanging until timeout on every single call.
- **`open --stdout`/`--stderr` (used by `tools/e2e_smoke.sh`) does NOT
  capture Dart's own `print()`/`talker` output** — only native C-level log
  lines (libobs' `blog()`) show up in that file. To see Dart-side output
  while debugging, run the built binary directly from Terminal instead of
  via `open` (accepting that Screen Recording permission then attributes to
  the Terminal, per the launch-context gotcha above — fine for anything that
  doesn't need real capture, e.g. testing thumbnail generation against an
  already-recorded clip).

**UI layer rules (IA from `docs/superpowers/specs/2026-07-13-game-centric-redesign.md`;
visual system superseded by `docs/superpowers/specs/2026-07-25-broadcast-deck-design-system.md`):**
- All styling flows through `RewindTokens` / the text-theme extension in
  `lib/src/ui/theme.dart`. NO glow/BoxShadow, no gradients, no pill radii
  (`circular(999)`), no raw hex in widgets. Hover/press overlays must
  LIGHTEN (low-alpha white) — dark-on-dark overlays are invisible.
- **Hue is reserved for state; chrome is achromatic.** `interactive` (a
  neutral steel) paints every selection, primary fill and focus ring.
  `armed` = buffer running / game live / auto-clip on. `onAir` = a manual
  recording. `positive` = a good outcome. `danger` = destructive or failed.
  Never paint a nav row with a state color, or a state with `interactive`.
  `test/theme_contrast_test.dart` enforces WCAG AA on every token pair AND
  that `interactive` stays achromatic — retune tokens, never the test.
- **Every digit uses the numeral role** (`textTheme.numeral` /
  `numeralLarge`, IBM Plex Mono): timecodes, durations, sizes, K/D/A, buffer
  seconds, counts. Never `copyWith(fontFeatures: tabularFigures)` by hand.
- Fonts are BUNDLED (`assets/fonts/`, see `docs/THIRD_PARTY.md`). Archivo =
  display, Inter Tight = UI, IBM Plex Mono = numerals. The first two are
  VARIABLE: any non-default weight must set `fontVariations` as well as
  `fontWeight`, or the engine synthesizes a fake bold instead.
- **One pill is allowed: `Switch`** (declared in `switchTheme`). Its shape is
  its affordance — a rectangular switch reads as a segmented control. Every
  other stadium/pill radius stays banned.
- One icon family: `*_outlined` for interface icons. The three transport
  glyphs (`play_arrow`, `pause`, `stop`) stay filled — a hollow play
  triangle is illegible at 20px.
- Navigation: `shell.dart` = rail + destination on a sealed
  `shell_destination.dart` value. No router/state-management packages.
- **The recorder is a BUTTON at the top of the rail, never a bar.** Two
  persistent strips (top, then bottom) were built and rejected on sight. The
  reason is structural, not taste: while you're gaming this window is behind
  a fullscreen game, so permanent in-window chrome is invisible exactly when
  it matters — which is also what ShadowPlay (overlay only) and Medal (one
  corner button + dropdown) do. The always-on indicator belongs in the tray
  (`TrayService` sets a live menu-bar title). Settings has no rail, so
  `Shell` hands the same `RecorderButton` to its sidebar — that is what keeps
  REC state visible on the screen most likely to be opened mid-match.
- **Zero idle animation.** Nothing may animate while the app sits in the
  background — a never-ending animation once measured ~45% app + ~45%
  WindowServer CPU. The deck's 1s ticker is the only repeating timer and is
  bounded on both sides (stops when a recording ends and when the buffer
  ring fills).
- **Focus rings go ON TOP — wrap interactive surfaces in `FocusRing`.**
  Material's own highlight is invisible here: `InkWell` paints `focusColor`
  into the enclosing Material's ink layer, BEHIND its child, and every
  interactive surface in this app (nav rows, filter chips, session cards,
  clip tiles) draws an opaque background as that child. Measured on the real
  app, tabbing between filter chips moved ~25 levels on one row of
  anti-aliased fringe, and moved the nav rows not one byte. Focus takes
  `interactive` — it is an affordance, not machine state.
- **Reduce motion is honoured, not ignored.** macOS's setting arrives as
  `MediaQuery.disableAnimationsOf(context)`. Flutter applies it to its own
  route transitions but NOT to anything we animate ourselves, so the two
  places that move on purpose — the shell's destination `AnimatedSwitcher`
  and onboarding's page turn — read it and collapse to `Duration.zero`. Any
  new deliberate motion must do the same.
- **Never rotate a hue and assume it stays legible.** Perceived luminance is
  weighted 0.72 green / 0.21 red / 0.07 blue, so the event system's violet
  arm — same saturation and lightness as its amber seed — landed at 3.3:1 and
  failed AA while the amber sat above 7:1. Derive the lightness from the
  requirement instead: `legibleOn(color, surface)` in `theme.dart`.
  `theme_contrast_test.dart` checks the DERIVED badge colours, not just the
  seed, because the seed is never painted.
- All Clips and every game hub render the SAME `SessionCard`; they differ
  only in scope. Don't add a second card shape for either.
- **The `SessionCard` label line is two Texts, not one.** Context (game,
  champion, mode) ellipsizes; the age never does. As one joined string the
  ellipsis ate the timestamp — the key the grid is sorted by — on every
  narrow card.
- Beware Flutter's flex-allocation trap: several loose `Flexible(flex: 1)`
  children + a `Spacer` in one Row each get an equal SHARE of free space
  whether used or not — trailing buttons end up stranded mid-row. One
  `Expanded` filler per row.

**Screenshots of the UI — read `.claude/skills/screenshots/SKILL.md` first:**
- `screencapture` from a terminal fails here (`could not create image from
  display`) because Screen Recording is not GRANTED — not because it's
  impossible. The grant would go to **Terminal.app** (the responsible app),
  and macOS only applies it after quitting and reopening it, which ends the
  Claude Code session. So don't retry it inside a task; ask for it only when
  you need something outside the Flutter tree (the menu-bar `● REC` title,
  the tray menu, native window chrome). Everything in the widget tree should
  use the test path below instead — it's deterministic and CI-safe.
- **NEVER capture the screen from inside Rewind.** Rewind holds Screen
  Recording permission, so a debug trigger shelling out to `screencapture`
  works with no terminal grant — which is exactly why it's tempting. It was
  built and removed on 2026-07-26: it starts a SECOND screen-capture client
  beside the app's own ScreenCaptureKit session, and the replay buffer died
  six minutes later, silently dropping eight clips across three live matches.
  This app's whole job is capturing the screen; anything else that captures
  the screen is competing with it.
- The working path is an integration test that renders into a
  `RepaintBoundary` and calls `toImage()` — pure Dart on the real GPU inside
  the app's own process, so the OS screenshot API (and its permission) is
  never involved. macOS's `integration_test` plugin also has no
  `captureScreenshot` channel, so `takeScreenshot()` is not the answer either.
- Two tours exist: `integration_test/ui_tour_test.dart` (individual screens)
  and `integration_test/redesign_tour_test.dart` (the whole shell in five
  states). Run with `flutter test <file> -d macos --dart-define=SHOT_DIR=after`.
- For a BEFORE/AFTER across branches, write the tour against only the API that
  exists on BOTH trees (go through `Shell`, whose prop list is deliberately
  stable), keep it untracked, and `git checkout` the base branch IN PLACE to
  re-run it. A `git worktree` fails — a fresh worktree can't resolve the macOS
  runner's Swift Package Manager dependencies.
- ALWAYS Read the PNGs back and look at them. A passing tour proves nothing;
  the images are the artifact.

**Testing gotchas:**
- Never pipe `flutter test` through `tail`/`grep` when the exit code matters
  — pipes mask failures. Redirect to a file and `echo $?`.
- Prefer bounded `pump(Duration(...))` over `pumpAndSettle` on shell/deck
  screens. (Historical: the REC dot used to animate forever, so settle
  could never return; the dot is static now — see `_PulseDot`'s doc — but
  bounded pumps remain the safe default since any timer-driven widget,
  e.g. the mic-test meter's poll, reintroduces the hang.)
- `PlayerScreen` cannot be built in widget tests (media_kit needs native
  libmpv); tests assert navigation by route name (`playerScreenRouteName`).
- Real `dart:io` file work inside `testWidgets` bodies hangs the fake-async
  zone — use plain `test()` or fakes.
- Thumbnails: `FfmpegThumbnailGenerator` (ffmpeg_kit-backed; FFmpeg
  binaries absent in the test host) must never be constructed in tests — fake the
  `ThumbnailGenerator` seam instead (`test/fakes/fake_thumbnail_generator.dart`).
  That fake writes with the `*Sync` `dart:io` calls deliberately: the async
  variants hang forever if a `ClipTile` widget test triggers them (via
  `FutureBuilder` calling `ThumbnailCache.ensure` during build) — this is
  the previous bullet's gotcha in disguise, since `testWidgets` bodies run
  in a fake-async zone. Sync IO blocks the call stack instead of scheduling
  a real completion, so it works from any zone; bounded `pump()`s alone are
  then enough to observe the placeholder-to-image swap.
- Tall screens need `t.view.physicalSize` widening or off-screen widgets
  never build.

## Conventions

- Dart: follow `flutter analyze` / `dart format`. Lints in `analysis_options.yaml`.
- C: C11, no C++ in the shim (keeps `dart:ffi` binding simple — no name mangling).
- Native support ships macOS AND Windows minimum (Linux when the primitive
  exists); prefer shared C in the shim over per-platform channels. If a
  platform channel is unavoidable, define it with pigeon (never a raw
  MethodChannel); new C FFI surface is generated with ffigen from
  `native/shim/rewind_obs.h`, not hand-written (the existing hand-written
  bindings predate this rule — don't grow them by hand). See
  CONTRIBUTING.md → Conventions.
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`). This drives the changelog and release notes.
  - **Do NOT add a `Claude-Session:` trailer** (or any AI-session link / "Co-authored-by: Claude" / "Generated with" line) to commit messages or PR bodies. Keep messages clean — subject + body only.
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
