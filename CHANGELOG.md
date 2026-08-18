# Changelog

All notable changes to Rewind are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- **Onboarding no longer asks Windows and Linux users for a permission that
  does not exist.** The Screen Recording step was shown on every platform,
  and since only macOS gates screen capture, everyone else got a green
  "Screen Recording is granted — you're set" for something they were never
  asked and never granted — then went looking for a setting their OS does
  not have. The step now appears only where the OS actually gates capture.

## [0.2.0] - 2026-08-17

### Fixed
- **The Windows build no longer ships without the Flutter engine's own
  data.** Bundling the libobs runtime deleted `data\` before copying libobs'
  files into it — the same directory Flutter keeps `icudtl.dat`,
  `flutter_assets\` and `app.so` in. v0.1.0's installer and portable zip
  contained neither, so `rewind.exe` exited during engine startup on every
  machine, before any of the app's code ran. The bundle step now merges into
  `data\`, clearing only the subdirectories libobs owns, and fails loudly if
  Flutter's data is not there afterwards.
- **The Windows shim now exports its functions.** `rewind_obs.dll` was built
  with an empty export table — ELF and Mach-O export every non-static symbol
  by default, a Windows DLL exports nothing unless asked — so the first FFI
  call out of `main()` threw `Failed to lookup symbol
  'rewind_list_displays' (error code 127)` and startup died before the first
  frame. Every declaration in `native/shim/rewind_obs.h` now carries
  `__declspec(dllexport)` on Windows.
- **Rewind now starts on a clean Windows machine.** Every binary in the
  Windows build — the app, each Flutter plugin, libobs and its plugins —
  imports the Visual C++ runtime (`MSVCP140.dll`, `VCRUNTIME140.dll`,
  `VCRUNTIME140_1.dll`), and neither the installer nor the portable zip
  shipped it. It arrives with Visual Studio, so every build machine had it
  and no user did: Windows resolves imports before any of the app's code
  runs, so Rewind died at process start with no window and — the reason this
  was so hard to diagnose — no log file, since logging is Dart code that
  never got to run. The runtime is now shipped next to `rewind.exe`.

### Added
- **CI now checks that the app launches, not just that it builds.**
  `integration_test/launch_smoke_test.dart` runs the real entrypoint on
  macOS and Windows and asserts it reaches a rendered frame and writes a
  session log. `tools/check_bundle_deps.dart` additionally verifies every
  Windows bundle is self-contained — the load-time failure above cannot be
  caught by launching the app in CI, because CI runners have the missing
  runtime preinstalled.

### Changed
- **New design system: "Broadcast Deck."** Rewind now reads like the video
  deck it is. The one rule is that **hue is reserved for state** — the mint
  accent had come to mean seven unrelated things at once (rail selection,
  primary buttons, the live-game dot, the focus ring, kill counts, the WIN
  badge, auto-clip on), so a glance could not separate *where you are* from
  *what the machine is doing*. Selection and buttons are now a neutral steel;
  amber means the buffer is armed, red means a recording is running, green
  means a good outcome, and nothing else carries colour.
- **The recorder is one button in the sidebar that opens a panel** — capture
  source, buffer length, Save clip and Record — instead of a row of controls
  taking up permanent space. The button itself reports the state (armed,
  recording, waiting for a game, unavailable) and how long the buffer is. It
  appears on **Settings** too; opening Settings mid-match used to hide whether
  anything was recording at all.
- **The menu-bar icon now says when you're recording.** While you're gaming
  Rewind's window is behind the game, so the menu bar is the only place that
  can actually tell you anything — and it was staying silent, spending what it
  knew on menu labels you had to open the menu to read.
- **Fonts ship with the app** (Archivo, Inter Tight, IBM Plex Mono). Rewind
  previously rendered in whatever the OS provided, so it was literally a
  different design on Windows than on macOS. Every number in the app —
  timecodes, durations, sizes, K/D/A, counts — is now set in a real monospace.
- **All Clips and each game hub show the same session card.** They present the
  same thing at the same level and used to do it two different ways, with two
  different card sizes. All Clips also gains sorting (newest / largest / most
  clips), and card size now follows window width instead of being fixed, so a
  large display shows bigger clips rather than more of them.
- **A game hub leads with how you have been playing**: matches, win rate,
  average KDA and disk use, replacing the old "42 clips · 2.4 GB · last clip
  2 h ago" line. Nothing is invented — a figure that was never recorded is
  left out rather than shown as zero.
- **Plainer language.** A hub's status now reads "IN MATCH · CLIPS ITSELF",
  "KNOWS WHEN YOU PLAY" or "HOTKEY ONLY" instead of "LIVE CLIENT API",
  "PROCESS DETECTION" and "MANUAL CAPTURE", which described how Rewind is
  built rather than what you get.
- **First run teaches the buffer** instead of describing it: a diagram of the
  rolling window ending at NOW, and the point everything else depends on —
  Rewind is already rolling, so you don't press record, you press rewind.
- **Saving a clip says what it saved**: the confirmation now names the moment,
  its game and its size, and offers "Show me". It was a bare "Clip saved".
- The player leads with the moment ("Penta Kill") rather than the game name,
  and its event markers gained a readable legend beneath the seek bar instead
  of being 3px ticks you had to hover one at a time.

### Added
- **A game's icon no longer disappears with the drive it came from.** Icons
  taken from a macOS app bundle (or picked by you) were stored as a path into
  wherever they lived — for a game installed on an external drive, a path that
  stops existing the moment the drive is unplugged, dropping the game back to
  a letter monogram. Rewind now keeps its own copy, which also survives the
  game being moved or uninstalled.
- **Windows/Wine games show their real icon.** Rewind reads the icon out of
  the game's own `.exe`, but only understood the modern PNG form — every icon
  stored the classic way (most of them: three of four executables on the test
  machine) came back empty and left a letter monogram, indistinguishable from
  a game that has no icon at all. Both forms are read now.
- **Games get their real icon and name on their own.** A game added from the
  "is running" banner or by picking it as a capture source kept a letter
  monogram forever — icon resolution only ran on one of the three ways to add
  a game, and both icon sources (the Steam library, and the icon embedded in
  the game's own .exe) need the game to be running. Rewind now resolves one
  the next time the game is live. You can also point at your own picture, on
  the game's settings page, for when there is nothing to find or the resolved
  icon is wrong.
 **You can remove a game** (Settings → the game → Remove). It forgets that
  game's settings, custom name and icon — the fix for a wrong icon — and stops
  detecting it for good. Previously nothing could undo adding a game: "Reset
  to defaults" only cleared the overrides and left the game in the list, still
  watched. Clips are a separate, explicit choice: the confirm dialog offers to
  delete them, and left unchecked they stay exactly where they are. Adding the
  game again brings it back.
- **You decide how long Rewind keeps its own logs** (Settings → Storage →
  Diagnostic logs), with the current size shown next to it. Retention used to
  be two unrelated hardcoded rules — the last 10 session logs, and 14 days of
  performance samples — so "how long does Rewind keep logs?" had two answers
  and neither was yours to set. They now age out together on one policy,
  applied the moment you change it rather than at the next launch. Blank keeps
  them forever.
- **libobs' own log now lands in the Logs screen and the log file.** When
  capture fails, libobs is the component that knows why — a module that would
  not load, an encoder that would not start, a stream the OS tore down — but
  it writes to stderr, which a packaged app discards. Rewind could report
  "buffer not running" while the reason was thrown away. A whole evening's
  clips were lost to exactly that, and the logs could not say why.
- **Deaths can be auto-clipped.** They were always detected — they feed each
  match's K/D — but there was no way to keep them, and nothing on screen said
  so. Reviewing how a fight went wrong is a real reason to save a clip, and
  the app already let you toggle DEFEAT and TURRET KILL, neither of which is
  rare. Off by default, because it strictly adds clips to every match — how
  many depends on how you play — so it's opt-in. A fight you also got a kill
  in still badges the kill.
- **Reset to defaults**, on each Settings page and on each game's page. Scoped
  per page rather than per app, so one button can't mean "throw away my
  hotkeys and my storage limits and my per-game setup" at once — and the
  confirmation names exactly what's about to change. Resetting a game simply
  stops it overriding anything; its clips are untouched.

### Fixed
- **Audio glitches while recording, when a launcher was open beside the game
  you were playing.** Two capture loops traded the aim nine times in three
  seconds — rebuilding the screen-capture stream each time, half of them at a
  window the system had already closed. Nothing takes the capture aim from a
  game you are playing any more; when a second game launches, it takes over
  once and then holds it.
- **Thumbnails stopped appearing after opening a match.** Every visible clip
  asked FFmpeg for a thumbnail in the same instant — eighteen at once on a
  real match. That overran FFmpeg's own session registry, and the sessions it
  evicted came back as an error Rewind recorded as "this video is broken",
  so those clips never got a thumbnail again. They are now generated a couple
  at a time, which also stops eighteen video decodes competing with the game
  being captured.
- **An exported match no longer poses as a clip.** Exports were written
  beside the clips, so the next launch adopted the file as a stray manual
  clip: it showed up under **Desktop** instead of the game it came from, and
  it counted against the storage limit as if it were original footage — a
  764 MB export, 75% of one user's limit, whose adoption evicted 18 real
  clips to make room for a second copy of footage they already had. Exports
  now live in their own folder, and the match screen is where you find them.
- **Exporting a match twice no longer swallows the first export.** Once an
  export was filed into its own match, the next export treated it as source
  footage — 43 MB of clips became a 258 MB video, then a 516 MB one. Only
  captured footage feeds an export now.
- **Clips say how long they are**, before their size — the question when
  picking something to watch. Existing clips are read once in the background.
- **A derived video says what it is.** An export inherited its first clip's
  badge and read "MANUAL", indistinguishable from the ordinary clips around
  it; exports and trims now badge **FULL MATCH** and **TRIMMED**, and an
  export leads its match's grid.
- **An exported match now lives in the match it came from.** "Export as one
  video" only ever pointed at the file through a six-second Reveal action, so
  once that toast went the video was unreachable from inside Rewind. The
  export now joins its own match, badged **Full match** — the same rule
  trimming already follows — so it can be played, revealed and deleted like
  any other clip, from the game it belongs to.
 **Rewind no longer holds your microphone (or a screen-capture stream) while
  paused.** With "only record while playing" on and no game running, macOS
  showed its microphone indicator anyway — the app was listening while its own
  UI said it was idle. Pausing released the video source and nothing else; the
  mic and the system-audio source both stayed open. System audio was the worse
  half: on macOS it is a ScreenCaptureKit stream, so a paused Rewind also kept
  the screen-recording indicator lit and held that stream around the clock.
  Both are now released when capture pauses and rebuilt when it resumes.
- **Match cards printed K/D/A twice.** The same three numbers appeared over
  the thumbnail as "7/6/11" and again in the footer as "7 K 6 D 11 A" — two
  notations for one fact, taking most of a small card's ink between them. The
  footer copy stays: it sits on an opaque surface, labels what each number
  means, and has room for creep score.
- **Library sizes now roll over to GB.** A library was reported as "1014 MB"
  while the storage limit it is measured against is set in GB, leaving you to
  divide by 1024 to compare the two.
- **Ages no longer jump from hours straight to a date.** "16 h ago" was
  followed by a bare `2026-07-29` the moment a day passed, so one row of cards
  could carry two different time systems. Days are now counted up to a week.
- **A game's real icon now appears on its own hub and its cards**, not just in
  the rail. (League is deliberately unaffected — its app icon is Riot's
  official logo, which their policy forbids using, so it keeps the monogram.)
- **Settings: capture mode showed nothing selected on most games.** Auto-clip
  defaults to on, and the mode was worked out as "auto-clip on = Highlights"
  without checking whether Highlights was even offered — so on any game
  without an in-game event feed (most of them) both radio buttons rendered
  empty and the mode looked unset. It now reads Manual only, correctly.
- **Settings → Storage now shows your storage.** It listed the total and the
  limit as two unrelated lines and left the ratio to you; there is now a
  usage meter, with a warning as you approach the limit and clips start being
  evicted.
- **Settings → About now shows the version**, and links the licenses of
  everything bundled. Neither existed, which made "what version are you on?"
  unanswerable from inside the app — including for anyone about to press the
  Report an issue button next to it.
- **"Blank = never" was a hint pretending to be a value.** The retention
  fields now say what an empty field means underneath them, permanently, and
  their units stay visible while they're empty.
- **Clearing a hotkey now says what that means.** The ✕ removed the shortcut
  silently, in an app whose whole premise is a shortcut.
- Settings pages share one row grammar and gained section headings; fields are
  sized to what you type into them; the content column stays anchored to the
  sidebar instead of drifting right as the window grows; the close button is
  no longer the only circle in the app; and a running game shows its live dot
  in the Settings sidebar too.
- **The window is now designed for more than one size.** The rail was a fixed
  220px at every width — 27% of a half-screen window, on an app meant to sit
  *beside* a game — and now collapses to icons (with tooltips, and the
  live-game dot moved onto the game's avatar) below 1000px. On a wide display
  the opposite problem: a 2200px window rendered a ~900px app hugging the left
  edge, because a hub's header blocks stopped at one width while its card grid
  ran the full window. Every block on a screen now shares one content column,
  centred once the window outgrows it, and card size steps with that column so
  a bigger display shows bigger clips rather than more small ones.
- **A game hub's header had two different right edges** — the capture-settings
  card was never actually width-capped (a `ConstrainedBox` cannot shrink below
  a tight constraint), so it ran wider than the score band above it.
- **WIN / LOSS badges could disappear on a bright frame.** They sat on an
  arbitrary video still with only a colour wash behind them; they now carry
  the same dark scrim as the K/D badge beside them.
- **A game hub said "In match — connected to 127.0.0.1:2999".** It now says
  what that means for the player.
- **Win rate could read "100%" off a sample of two.** A game hub reported a
  percentage over only the matches whose outcome Rewind managed to record —
  on a real library that was 2 matches out of 21, both wins, so the hub
  claimed a perfect record. It now shows a **record** ("2-0") and spells out
  the sample whenever some matches are unrated ("RECORD · 2 OF 21"). A
  percentage hides its own denominator, which is the wrong property for a
  figure this sparse.
- **Losses were never recorded at all.** Every recorded outcome in a real
  library was a win. Rewind accepted only "Win"/"Lose" from League's match-end
  event, so a lost match reporting any other spelling was silently dropped —
  and nothing anywhere said so. It now accepts every plausible spelling, logs
  the raw value when it recognises none (so the next lost match names the
  exact token instead of vanishing), and still refuses to guess: an
  unrecognised result stays neutral rather than being written down as a defeat
  that never happened. A match-end that arrives after the game already closed
  now attaches to the match that just finished instead of being dropped.
- **Hotkey clips taken during a match now appear in that match.** They could
  end up filed under the game's launcher instead of the live match and strand
  themselves as one-clip groups beside the match they came from. Sessions are
  now grouped by time as well as by stamp: a clip that falls inside a match's
  span belongs to it. This also repairs clips already saved that way, without
  rewriting anything on disk. Two back-to-back matches still never merge —
  absorption requires containment, not proximity.

### Accessibility
- Screen readers can now read the recorder state, the live-game dot, clip
  counts, K/D/A, match results, event badges, the buffer diagram and every
  timeline marker — all of which previously conveyed their meaning through
  colour and position alone.
- WCAG AA contrast is enforced by a test across every colour pair rather than
  documented in a comment, so a future palette change cannot silently regress
  it.
- The "⟨game⟩ is running" banner's buttons grew to a comfortable target size;
  they were small enough, and close enough to the dismiss ✕, to invite
  misclicks at exactly the moment a game launches.

### Added
- **Record the whole play session (per game)**: a new "Full session" toggle
  on each game's settings page records the entire session to one continuous
  video while that game is running — in addition to the rolling buffer and
  its event/hotkey clips (both keep working; the session VOD groups with the
  match's other clips). Off by default; session files are large and obey the
  same storage retention as clips. Starts on game launch, saves on exit; a
  manual recording always takes precedence over the one recording slot.
- **Real game icons + trustworthy "game is running" suggestions**: Steam
  games run through CrossOver/Wine (e.g. R.E.P.O.) have no macOS app icon,
  so they used to show a two-letter placeholder. Rewind now reads the real
  icon (and the game's proper name — "R.E.P.O." over "REPO") from the local
  Steam library that's already on disk, showing it in the "Running now" list
  and on the home screen's detected-game banner. Crucially, the home banner
  now decides "is this app a game?" from Steam's own installed-games list
  rather than guessing — so it suggests the game you launched, not
  `explorer.exe` or `steamwebhelper`. Cross-platform (native Windows/Linux
  Steam paths and macOS CrossOver bottles). Non-Steam Wine games
  (itch/Epic/standalone) get their real icon read straight out of the game's
  own `.exe`; anything still unresolved falls back to the letter tile.
- **Win/Loss on match cards**: League match cards and the match screen now
  show a WIN (green) or LOSS (red) badge once the game reports the result
  at match end (read from the Live Client `GameEnd` event, which Rewind
  previously discarded). Recorded onto the match's stats and persisted;
  process-only games and pre-feature matches simply show no badge. The
  match-end moment also clips if you've enabled the "Match" event group.
- **Watch the full match in-app**: a match's screen now has a "Watch
  match" action — every clip laid on the REAL match timeline (recorded
  spans bright, unrecorded spans as visible gaps, kills/achievements
  marked at their true times, the current span highlighted), playback
  runs clip-to-clip chronologically and auto-jumps across gaps, and
  tapping anywhere on the timeline seeks — a tap into a gap jumps to the
  next recorded span. Clip spans come from real ffprobe durations, not
  guesses.
- **Export the full match as one video**: the movie action on a match's
  screen concatenates all its clips chronologically into a single
  shareable file next to the clips (`…-full-match.mp4`) — lossless
  stream-copy concat (same encoder settings across clips, so no
  re-encode), with a Reveal action on the confirmation toast. The
  individual clips are untouched.
- **"Running now" on Supported Games**: playing something the catalog
  doesn't know? The Supported Games screen now ends with a live list of
  running apps (probable games first, Windows/CrossOver exes included) —
  one Add click learns it as a game (same rules as picking it as a capture
  source: process auto-detection next launch, real app icon in the rail,
  no Riot-logo exceptions violated) without touching your current capture
  target.
- **Clip trimming in the player**: a scissors button opens trim mode — an
  FFmpeg-generated filmstrip of frames spans the trim surface (above the
  timeline), with editor-style grab handles over it; the trimmed-off ends
  dim so the kept span reads at a glance, dragging a handle seeks the
  player to the exact cut frame, and an in → out + "selected" readout
  tracks the range. "Save trimmed clip" exports
  the selection as a NEW clip next to the original — the confirmation
  toast carries a Play action that opens the trimmed result immediately
  (a result the user can't act on isn't a result) — losslessly
  (FFmpeg stream copy via `ffmpeg_kit_flutter_new`; the cut lands on the
  keyframe at/before the chosen start). The original clip is untouched;
  the trim is indexed into the library immediately with a "Trimmed"
  label. macOS + Windows (the package ships no Linux binaries yet — the
  button hides there rather than failing).
- **Mic test meter with level hints**: a "Test my mic" button (Settings →
  Capture → Audio, under the mic controls) opens a live level meter — speak
  a few words and Rewind tells you in plain language whether the mic slider
  is right ("Level looks good", "Too quiet — raise Mic volume", "Clipping —
  lower Mic volume") instead of making you record a clip and guess from
  playback. While game audio is flowing it shows a second bar and reports
  how far your voice sits above the game mix. Backed by a new
  `rewind_audio_levels_json` shim call (an `obs_volmeter` per audio source,
  post-filter and post-slider, so the meter shows exactly what lands in
  clips).
- **Mic noise suppression**: a "Filter background noise" toggle (on by
  default) attaches libobs' RNNoise `noise_suppress_filter` to the mic
  ahead of the auto-leveling chain, stripping keyboard clatter, fans, and
  room hum before the compressor can amplify them
  (`rewind_set_mic_noise_suppression`).

### Changed
- **Multikill badges now escalate by tier**: kill/double/triple/quadra/penta
  climb from amber toward a brighter gold instead of all sharing one amber,
  so a pentakill visibly stands out from a plain kill in the clip grid and
  match screen (all tiers stay AA-legible). Pairs with the multikill-tier
  fix above — the tiers finally render, so they finally look distinct.
- **Accessibility verified**: every icon-only button in the app carries a
  tooltip (doubling as its screen-reader label), the theme palette is
  WCAG 2.1 AA-verified — all five foreground tokens clear 4.5:1 against
  all three surfaces (tightest pair 5.01:1, documented in theme.dart so a
  retune re-checks instead of eyeballing) — and the app has no
  perpetually-running animations (the REC dot has been static since the
  idle-CPU fix).
- **Actions moved into the user's line of sight**: Watch match and Export
  are now prominent labeled buttons at the top of the match screen's
  content (they debuted as top-right app-bar icons — outside where the
  eye lands), and the player's Reveal in Finder / Open in default player
  sit on the transport strip next to the volume control instead of the
  header's far corner.
- **Thumbnails are generated by FFmpeg now** (`ffmpeg_kit_flutter_new`)
  instead of a headless media_kit player — one decoded frame via ffmpeg
  replaces the whole off-screen-VideoController / duration-race /
  stale-frame-sleep workaround pile (see CLAUDE.md's media_kit gotchas),
  and media_kit shrinks to what it's good at: playback.
- **FFI bindings are generated with ffigen** from `native/shim/rewind_obs.h`
  (`dart run ffigen --config ffigen.yaml`), replacing 30 hand-written
  `@Native` declarations; platform channels, if ever needed, must use
  pigeon (see CONTRIBUTING.md → Conventions).
- **In-app echo guidance**: Settings → Audio now explains, right under the
  mic controls, that speaker echo can't be removed after the fact and what
  actually works — headphones, or macOS Voice Isolation (Control Center →
  Mic Mode) — instead of leaving users to discover there's no echo
  cancellation the hard way.
- **UX polish pass**: a broken/missing clip now shows "Couldn't play this
  clip" with the underlying error in the player instead of an indefinite
  black frame with a dead seek bar; manual saves ("Save clip" button /
  hotkey) confirm with a "Clip saved" toast so the button never looks
  inert; Escape closes Settings like the ✕ button; the disabled Save
  clip/Record buttons explain why in a tooltip when capture is unavailable;
  "Open in default player"/"Reveal in Finder" report failures instead of
  silently doing nothing; the clip delete confirmation styles Delete as
  destructive; the detected-game banner's ✕ clarifies it dismisses for the
  session only; an event filter that matches nothing offers "Clear filter"
  instead of the first-run empty state.

### Fixed
- **Fullscreen games no longer record black**: a fullscreen game is now
  captured as the display it covers. Capturing it as a window (or as an
  app) returns black frames from ScreenCaptureKit, which is how a whole
  League session's clips came out completely black.
- **Capture keeps following a game that swaps its window**: the "follow the
  game" aim used to be decided once, when the game was detected. League
  replaces its window between the loading screen and gameplay, so that
  one-shot aim ended up pointed at a dead window for the rest of the match.
  Rewind now re-checks while the game runs and re-aims when the window
  changes. It also picks the newest on-screen full-screen window when a game
  leaves several behind, instead of whichever the system listed first.
- **Manual clips taken during a match now sit with that match**: pressing
  the hotkey (or "Save clip", or stopping a manual recording) mid-game could
  file the clip under the game's launcher instead of the match, so it landed
  in its own group in the library rather than alongside the match's other
  clips. Manual captures now attribute to the game actually being played.
- **Two matches no longer merge into one**: restarting Rewind while a game
  is running resumes the match it interrupted, which used to be guessed from
  how recently the last match was updated — so the NEXT match could be
  swallowed by the previous one's card, overwriting its champion and summing
  both scorelines. League now reports when the match actually began (the
  live API's own match clock), and the session is keyed on that, so a
  restart rejoins the right match and two matches stay separate even when
  they're played on the same champion.
- **League multikills now clip at their real tier**: the Multikill handler
  always emitted a "double kill" regardless of the actual streak. It now
  reads the event's `KillStreak` (2→double, 3→triple, 4→quadra, 5→penta),
  so a pentakill is finally saved and labeled as a pentakill.
- **Concurrent settings saves could wipe settings.json**: every save
  shared one `settings.json.tmp` scratch file, so two overlapping saves
  (e.g. rapid Settings changes) could publish a half-written JSON — which
  the corrupt-file recovery path then silently "fixed" by resetting ALL
  settings to defaults. Saves are now serialized (each write starts after
  the previous rename lands) with the JSON snapshotted at call time.
- **Mic auto-leveling was silently inert** — the `obs-filters` plugin
  (home of libobs' compressor/limiter/noise-suppression filters) was never
  in the SDK build allow-list, and libobs "creates" sources with
  unregistered ids as non-NULL inert placeholders, so the auto-leveling
  chain attached nothing and no warning ever fired. The plugin now ships on
  all three platforms (fetch recipe bumps: macOS 3, Windows 3, Linux 2) and
  the shim verifies filter ids are actually registered before creating
  them, logging loudly when they aren't.
- **User-renameable game display names**: auto-detected games used to
  surface raw executable-derived names ("PENGUINHOTEL-WIN64-SHIPPING")
  everywhere — the hub title, All Clips session headers, the rail, the MY
  GAMES sidebar. A new "Name" field at the top of each game's Settings page
  (MY GAMES → game) lets you rename it once and have the friendly name win
  everywhere, live, without restarting — the same commit-on-blur field as
  the Storage limits, snapping back to the derived name when cleared.
  Precedence is a config override (when set) ahead of the catalog/descriptor
  name ahead of generic title-casing. League and Marvel Rivals — the two
  games with a `games/game_descriptor.dart` entry — are not renameable in
  v1: renaming League would desync its two merged gameIds' names and break
  the All Clips bucket-by-display-name merge along with it, so the field is
  hidden for them.
- **Audio balance controls: game-audio volume + mic auto-leveling**: two
  levers for clips that mixed mic and game audio with no way to balance
  them. A "Game audio" volume slider (Settings → Capture → Audio, next to
  the existing audio-source picker) pulls game/desktop audio down under
  voice, mirroring the existing mic-volume slider but against the
  desktop-audio source (`rewind_set_game_volume`). "Auto-level my voice"
  (on by default) attaches libobs' own compressor and limiter filters to
  the mic source — a compressor evens out the recording envelope, a limiter
  catches whatever peaks through — so voice sits consistently against the
  game instead of swinging between too quiet and too loud
  (`rewind_set_mic_leveling`). Both apply live if the capture pipeline is
  already running. Not in this pass: capturing a specific friend's voice
  app separately (needs a third app-audio source), and multi-track audio in
  the mux (both would need mixer-level changes beyond these two per-source
  levers).
- **Audible feedback for manual saves and recording**: a short confirmation
  sound plays when the save hotkey (or `.save-now`) succeeds or fails, and
  when the record hotkey (or `.record-toggle`) starts/stops a manual
  recording — so pressing the save key mid-game finally tells you whether it
  worked, without alt-tabbing to check. Auto-clipped events (kills,
  achievements, etc.) deliberately stay silent — a chime for a save you
  didn't trigger would just be noise mid-fight. On macOS this reuses stock
  `/System/Library/Sounds` system sounds via `afplay` (zero bundled assets);
  Windows/Linux are no-ops for now (`ClipSounds`'s doc has the future
  recipes). Gated by a "Sound on save" toggle, on by default — now on
  Settings → Hotkeys (moved from Capture → Instant replay: it's feedback
  for the hotkeys, not a capture setting, and that's where a user looking
  for it goes first). A coalesced burst of save-hotkey presses (see the
  2026-07-18 coalescing fix) still plays exactly one sound, for the save
  that actually happened.
- **Steam achievement auto-clip, for any Steam game — keyless**: no Steam ID,
  no Web API key, no setup beyond the toggle in Settings → Steam (on by
  default). Detects unlocks by watching the local, read-only stats-cache
  files Steam's own client already writes to disk seconds after every
  unlock (`appcache/stats/UserGameStats_<accountId3>_<appid>.bin` for the
  unlock itself, the sibling `UserGameStatsSchema_<appid>.bin` for the
  achievement's real display name) — faster than polling a web API, and
  works offline. Every Steam install on the machine is watched at once:
  native Steam and every independent CrossOver bottle, each with however
  many accounts have logged into it, discovered from that install's own
  `config/loginusers.vdf` (the same file Task 23's onboarding auto-detect
  already reads). The achievement clip is labeled with its real name via a
  small tolerant binary-VDF parser written for this feature (no code copied
  from existing Steam-achievement tools — see docs/COMPLIANCE.md's Steam
  entry for the full reasoning, including the hard rule that Rewind must
  never WRITE to any file under a Steam install). Settings → Steam is now
  three sections: "Achievement clips" (the toggle + a plain-language live
  status line — "Watching — achievements will clip automatically", "No
  Steam installation found…", or idle while the toggle is off), "Steam
  account" (the local-detection line + a Detect refresh button, no bare
  fields), and a collapsed "Advanced — optional web API" disclosure holding
  the earlier Web API design (Steam ID + Web API key fields), retired as
  the trigger path but kept and clearly labeled optional — reserved for
  possible future enrichment. The "Game details must be Public" privacy
  note moved into that disclosure too, since it's a Web-API-only
  requirement that local detection doesn't need.
- **Marvel Rivals** added to the game catalog — process-detection only (no
  sanctioned real-time source exists: no public match/event API, and the
  game's own logs are encrypted). Works on Windows natively and on macOS via
  CrossOver. Its rail/hub icon is always the monogram, never the real app
  icon, out of caution absent a Marvel/Disney/NetEase fan-tool logo
  carve-out.
- **"Only record while playing"** (Settings → Capture → Instant replay,
  default OFF): opt in and the replay buffer auto-pauses whenever no game
  is detected, resuming the instant one activates — cuts the always-on
  desktop capture load (~30% CPU / 460 MB idle) for anyone who only wants
  game footage. Composes cleanly with the tray's manual Pause/Resume: a
  manual pause always wins, a manual resume forces the buffer on until the
  next game starts or ends, at which point the setting reclaims control.
  While auto-paused the deck's status line reads "Waiting for a game"
  instead of "Paused"; pressing the save hotkey during that window reports
  the same clear "buffer not running" error a manual pause already gives.
  For League of Legends specifically, this counts as playing only while a
  match is actually live, not just when the client is open.
- **Microphone input device picker**: "Record my microphone" now targets a
  specific input device instead of always using the system default. Pick
  one from Settings → Capture → Audio's new "Microphone" sub-row (mirroring
  the existing "From" row under system sound) — "System default" plus every
  enumerated input; a saved device that's since been unplugged just shows
  as "System default" without losing the choice. macOS only for now
  (CoreAudio device enumeration); Windows/Linux enumerate as empty and hide
  the picker until their backends grow the same device listing.
- **Mic volume slider + live listen**: set your microphone's recording
  level yourself instead of always recording it at 100% — a new "Mic
  volume" slider under Settings → Capture → Audio's Microphone row (0-200%,
  defaulting to 100%), and a headphones toggle next to it that monitors the
  mic live through your speakers/headphones while you tune it. Listening
  stops automatically when you toggle it off, leave Settings, or switch the
  mic off entirely — it's never left running unattended.
- **Always-on performance telemetry**: Rewind now samples its own CPU%/RSS
  and — the actually load-bearing signal for "capture is causing input lag"
  reports — libobs's frame-health counters (lagged/skipped frames) every
  10 s. Machine-readable lines land in `<support>/logs/perf-<session>.jsonl`
  (pruned after 14 days, alongside the existing session logs) for offline
  diagnosis; a compact human summary also goes to the normal log, only at
  visible (info) level when something looks wrong (a new lagged/skipped
  frame, or CPU over 50%) so a healthy session doesn't spam it.
- **Perf telemetry: render time, GPU utilization, thermal state**: the
  perf JSONL now also carries `obs_render_avg_ms` (libobs's per-frame
  compositor cost — the direct way to see a render-pipeline change),
  `gpu_util_pct`, and `thermal_state` (both macOS-only via IOKit/
  NSProcessInfo, -1 elsewhere); the human summary escalates to visible
  (info) level on thermal throttling (serious/critical) too.
- **Onboarding that proves it works**: the Screen Recording step is now
  live — it knows whether permission is granted, fires the macOS system
  prompt directly ("Grant Screen Recording"), flips to a checkmark the
  moment you approve, and is honest about the relaunch a mid-session
  grant requires (with a Relaunch button that does it). A new final
  "Try it now" step has you press the save hotkey and watches the real
  clip land. The games step names a supported game if it's already
  running. Setup choices (buffer, mic, follow-the-game) unchanged.
- **Event markers on the clip player's timeline**: kills, deaths and
  objectives are now timestamped as they happen (into `matches.json`;
  older matches predate the data and show a plain bar), and the player's
  seek bar draws a colored tick per event — click one to jump to 2 seconds
  before the moment. First step of the player roadmap (next: trimming, the
  full-match timeline view, and full-match export).
- **Configurable post-event delay for auto-clips** (default 5 s): how long
  Rewind keeps recording after the last event before saving the clip — a
  follow-up kill during the window extends the same clip (the burst logic
  that already existed, now user-visible). Set per game on its settings
  page, under the event chips ("Keep recording after the last event").
- **"Clean up now" in Settings → Storage**: runs the retention limits
  (max storage / max age) over the library immediately instead of waiting
  for the automatic sweep, and reports what it did ("Removed N clips ·
  freed X" / "Nothing to remove"). Protected clips stay untouched, same as
  the automatic sweep.
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
- **Game integrations are now registry-driven** (`lib/src/games/
  game_descriptor.dart`): the ~11 sites that used to hand-duplicate League's
  vendor-id/catalog-id pair (match presentation, the game-directory merge,
  the game hub, Supported Games, icon policy, the auto-clip event taxonomy)
  now resolve through one `GameDescriptor` registry and a `descriptorFor`
  lookup. Purely an internal refactor — League's behavior is unchanged; adding
  a new process-detected game (like Marvel Rivals, above) now needs only a
  catalog entry, no per-file special-casing. Also fixed VALORANT's
  `processMatch` to the real game binary (`VALORANT-Win64-Shipping`, not the
  launcher) and documented it as Windows-only, manual-capture-only
  permanently (Riot policy + Vanguard blocking CrossOver/VM).
- **Performance: in-game capture overhead reduced — canvas now renders at
  output resolution.** On a Retina display with a quality cap (the default),
  the render canvas previously stayed at the display's full native pixel
  size (e.g. 3024×1964) even though the encoder only ever saw the smaller
  capped output (e.g. 1660×1080) — every frame at 60fps was rendered onto a
  ~3.3x-larger-than-needed target, then bicubic-downscaled, then encoded,
  wasting GPU bandwidth that competes with whatever game is running. The
  canvas is now sized to the output resolution directly, eliminating that
  full-resolution render pass; the encoder was already hardware
  (VideoToolbox H.264), so this closes the remaining per-frame waste. The
  capture source itself is unchanged (still captures at native Retina
  pixels); it's now routed through a minimal internal scene so it scales
  down to fit the smaller canvas instead of being drawn 1:1 (a bare
  channel-0 source has no scale-to-fit at all — it would otherwise crop to
  the canvas's top-left corner). No visible change when the display isn't
  capped (native resolution already equals output). Uncapped/no-op cases
  aside, downscaling now happens via a single bilinear pass instead of the
  previous multi-tap bicubic — a deliberate tradeoff to actually realize the
  performance win (see `rw_attach_capture()`'s comment in
  `native/shim/rewind_obs.c` for why); mild at the reduction ratios a
  quality cap typically produces.
- **"Only record while playing" is now ON by default** (was off): fresh
  installs, and existing settings files with no stored value, now pause the
  replay buffer at the desktop and resume it automatically the moment a game
  is detected (League: when a match goes live), matching what most players
  actually want out of the box. Anyone who already toggled it explicitly —
  on or off — keeps their choice; only the *absent-key* case changed. The
  "Try it now" step of the getting-started guide keeps the buffer running
  regardless (its whole point is a desktop save), and now explains the new
  behavior in a line of copy, pointing at Settings → Capture → "Only record
  while playing" for anyone who wants always-on desktop recording back.
- **Match detail screen is now a generic session frame**: the champion/K-D-A
  summary band, roster disclosure, and kills footnote moved behind a new
  per-game `MatchPresentation` seam (`lib/src/games/match_presentation.dart`),
  with League's first implementation under `lib/src/games/league/`.
  `MatchClipsScreen` itself no longer imports anything League-specific;
  process-detected games with no presentation impl render the bare frame
  (app bar + clip grid). Internal architecture only — no visual or
  behavioral change for League.
- **Match detail screen compacted**: one summary band (champion · mode ·
  K/D/A/CS/WS · items) instead of a tall card, the full-roster chips
  collapsed behind "Champions in this game (N)", the duplicate stats line
  removed — the clips grid gets the space.
- **Settings rebuilt as a full-page screen** (research-backed redesign —
  competitor teardown of 8 apps + NN/g/HIG/Material evidence + preset-design
  research): Settings now covers the whole window with its own sidebar as
  the only navigation (✕ returns to where you were). GENERAL pages
  (Capture, Hotkeys, Storage, About — Quality folded into Capture) plus a
  **MY GAMES section with a per-game page for every configured game**
  (capture mode as "Manual only / Highlights" cards, event chips, buffer
  override, post-event delay, detection info). Content is left-aligned in a
  720px column, grouped by whitespace and section headers, controls at the
  trailing edge, one "› Advanced options" disclosure per page. **Video
  quality is now three outcome-worded presets + Custom** — Performance
  (1080p·30), Balanced (1080p·60, recommended, the new fresh-install
  default in place of native res), High (1440p·60) — each printing its
  honest disk cost ("30 s buffer ≈ 75 MB"); raw resolution/framerate rows
  live under Custom. Audio is two plain toggles ("Record game & system
  sound" on by default, "Record my microphone" off until opted in). The
  **game hub's inline capture editor is replaced by a glanceable summary
  card** ("30 s buffer · Auto-clip ON · 6 events") that opens the game's
  settings page — collapsed means summarized, never hidden. Existing
  settings files keep all stored choices, including a deliberate
  Source-resolution pick.
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
- **All Clips now groups by match/session across games, newest first**,
  instead of one flat grid per game — each play session gets a tappable
  header (game + relative time + clip count) opening the same match detail
  screen the game hubs use, with its own clip grid beneath, interleaved by
  recency rather than partitioned by game. Clips opened from All Clips now
  carry their event timeline markers too, closing the gap with the per-game
  hub view.

### Fixed
- **Restarting the app mid-match no longer records black** — a
  fullscreen-exclusive game window sits on an elevated window layer, and
  the capture-source enumeration filtered all non-zero layers out, so a
  cold start mid-match couldn't find the game window at all (capture fell
  back to the hidden League client and recorded black until the match
  ended). Display-covering windows now pass the filter whatever their
  layer.
- **Restarting the app mid-match no longer splits the match in two** — the
  match card is keyed by the session stamp, which used to be minted fresh
  on every activation. The first activation after launch now resumes the
  previous match session when its stats were still updating within the
  last 3 minutes (i.e. the restart interrupted it), so clips and K/D keep
  accumulating on the same card.
- **Mic auto-leveling no longer boosts the mic** — the compressor carried
  a fixed +6 dB makeup gain, pushing voice above the game mix regardless
  of the mic volume slider (clips true-peaked at 0.1 dBFS). The chain now
  only evens out peaks; the slider alone sets the level.
- **Storage limits no longer apply per keystroke** — typing "15" into Max
  storage passed through "1", and the immediate retention sweep deleted
  clips at the transient 1 GB limit with no confirmation. Limits now
  commit only when you leave the field; invalid text snaps back; the
  Clean up button remains the explicit immediate path.
- **The hotkey field shows the newly captured combo immediately** — the
  new binding was applied correctly, but the field kept displaying the old
  combo until you left the page.
- **Process-detected games no longer offer "Highlights"** on their
  settings page — there's no event feed to auto-clip from, so the
  capture-mode choice was a lie; a plain statement of hotkey capture
  replaces it.
- **Running fullscreen games now appear in the capture-source picker
  (macOS)**: app enumeration listed only windows on the active Space, so a
  game — almost always fullscreen on its own Space — was invisible the
  moment you switched to Rewind to pick it. Enumeration now spans all Spaces
  and reports each window's on-screen visibility.
- **The capture-source picker no longer disappears when no displays
  enumerate (macOS)**: it was hidden entirely whenever the startup display
  list came back empty (a display asleep/clamshell, the screen locked, or a
  game holding a Space), which removed the only app-picker in the main
  window for the whole session. It now shows whenever anything is pickable.
- **A saved capture-display choice is no longer erased when display
  enumeration returns empty**: an empty list means enumeration failed, not
  that the monitor was unplugged, so the choice is kept and applied (only a
  non-empty list that lacks the display now drops it). Previously this
  silently fell capture back to the main display and recorded the wrong
  monitor.
- **"Follow the game" auto-switch now binds to the on-screen game window,
  not a hidden lobby (macOS)**: native League runs its client/lobby and the
  in-match window as separate windows both named "League of Legends";
  capture could bind to the lobby and record the wrong screen. The
  auto-switch now prefers the visible match; the picker still lists every
  window.
- **League clips no longer record a black screen during matches (macOS)**:
  League is two separate apps — the client the user browses lobby/champ-select
  in, and a distinct game app that only exists mid-match. Capture stayed
  bound to the (by then hidden) client for the whole match, recording nothing
  but the cursor over a black canvas. Capture now re-aims at the actual game
  process the moment a match goes live, retrying for a few seconds if the
  game app's window hasn't enumerated yet (e.g. during the loading screen).
- **DRM apps (Netflix, Crave, etc.) showed black video while Rewind idled**:
  pausing the replay buffer ("Only record while playing", or a manual tray
  pause) stopped the buffer output but left the underlying screen-capture
  source live — macOS still saw an active ScreenCaptureKit session, which is
  exactly what DRM playback blanks its video against, and kept the
  screen-recording indicator lit for no reason. Pausing now releases the
  capture source entirely and recreates it on resume, so a paused Rewind
  holds no capture session at all — DRM video plays normally, the indicator
  clears, and idle GPU/CPU cost drops further.

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
