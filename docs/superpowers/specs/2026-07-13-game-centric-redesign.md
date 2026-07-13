# Game-centric UI redesign — spec

Date: 2026-07-13. Status: approved for implementation.
Scope: UI/IA only. Capture pipeline, coordinator logic, settings model, and tests for them stay intact
except for the two small additive seams called out in §4 (T2).

## 0. Design direction (summary)

The game is the entry point. A persistent left rail lists the user's games (detected, configured, or
with clips) plus All Clips and a Supported Games catalog; each game opens a hub that owns that game's
clips, event filters, integration status, and inline per-game settings. A slim "recorder deck" status
bar stays pinned across every screen: REC state, buffer length, capture source, Save Clip. Visual
language keeps the mint `#3DDC97` identity but drops Material-3 pill shapes for a sharp, dense,
rectangular system — hairline borders, uppercase tracked labels, tabular numerals, system fonts,
no glow/bloom anywhere (the pulsing dot's boxShadow goes). Everything below is feedable from
existing fields; no invented stats.

## 1. Information architecture

```
┌──────────┬──────────────────────────────────────────────┐
│          │ STATUS BAR  ● REC · 30s ▾ · Capturing: LoL ▾ · [Save clip] │
│  REWIND  ├──────────────────────────────────────────────┤
│          │                                              │
│ ALL CLIPS│                                              │
│ ─────────│              CONTENT AREA                    │
│ GAMES    │   (All Clips / Game Hub / Supported Games /  │
│ ● League │    Settings / Player)                        │
│   CS2    │                                              │
│   Desktop│                                              │
│ + Add game                                              │
│ ─────────│                                              │
│ Settings │                                              │
│ Logs     │                                              │
└──────────┴──────────────────────────────────────────────┘
```

Navigation shape: a 220 px fixed left rail + a content area, inside one top-level `Shell` widget.
Plain `StatefulWidget` navigation (a sealed `ShellDestination` value: `allClips`, `game(gameId)`,
`supportedGames`, `settings`) — no router package, no state-management framework. The Player remains
a pushed full-screen route (as today) since it's modal playback, not a destination.

Rail contents (top to bottom):
1. Wordmark block: "REWIND" uppercase w800, tracked.
2. **All Clips** — the cross-game library (Desktop clips included).
3. **GAMES** section label, then one row per *library game*. A game appears here when ANY of:
   it has a `GameConfig` row (`AppSettings.allConfigs`), it has clips (`ClipLibrary.all` gameIds),
   or it is currently active (`ClipCoordinator.activeGameIds`, new — §4 T2). `desktop` is pinned
   last as a pseudo-game (manual clips home). Sort: active games first, then alphabetical by
   `displayNameFor`. Each row: name + right-aligned live dot (mint, static, only when active) +
   clip count (tabular, muted). Selected row gets a 2 px mint left bar + raised surface — no pill.
4. **+ Add game** — opens Supported Games.
5. Bottom: **Settings**, **Logs** (pushes the existing TalkerScreen).

The status bar (today's `StatusStrip`, restyled and slimmed to one 48 px row) is pinned above the
content area on every destination. It keeps exactly its current data wiring: buffer state
(`bufferActive` / `captureError`), active game chip (`coordinator.activeGame` + `displayNameFor`),
capture source chip (`displays`, `capturableApps`, `settings.captureDisplayUuid/captureAppBundleId`,
`autoSwitchedAppName`), buffer quick-set (`settings.bufferSecondsFor`), Save Clip
(`coordinator.onHotkey`), and the permission/error banner (which may expand the bar to a second row).

## 2. Visual language

**Palette** (evolves the existing theme.dart values; mint identity kept — it is already the brand,
distinct from NVIDIA's chartreuse and Medal's blue, and reads "fresh capture" against near-black):

| Token            | Hex        | Use |
|------------------|------------|-----|
| `bg`             | `#0C0E11`  | window background (deepened from #0E1114) |
| `surface`        | `#14171C`  | rail, cards |
| `surfaceRaised`  | `#1A1E24`  | hover rows, inputs, selected rail row |
| `hairline`       | white 8%   | ALL separation — borders, dividers; never shadows |
| `text`           | `#E6EAEF`  | primary text |
| `textMuted`      | `#8B94A1`  | secondary text, icons at rest |
| `accent`         | `#3DDC97`  | selection, primary action, live dots, focus ring |
| `accentPressed`  | `#2FB37C`  | pressed fills |
| `rec`            | `#FF4757`  | recording dot + destructive, nothing else |
| `warn`           | `#FFB74D`  | error/permission banner (existing amber, kept) |

Event badge hues: keep the existing `eventColor` accent-rotation scheme (mint = manual/victory,
amber rotation = kills, violet rotation = objectives, red = defeat). It already avoids the rainbow.

**Type**: system fonts only (SF Pro on macOS, Segoe UI Variable on Windows) — zero dependencies, no
GPL bundling question, and the gaming personality comes from *treatment*, not a display face (a
bundled esports font is exactly the AI-generated look to avoid). Scale:
- `display` 22/w800, letterSpacing −0.4 (screen titles, hub header)
- `title` 15/w700 (card headers, rail selected)
- `body` 13/w500, `bodyMuted` 13/w500 textMuted
- `label` 12/w600 (chips, buttons)
- `micro` 11/w700, letterSpacing 1.2, UPPERCASE (section labels, event badges, "GAMES", "LIVE")
- `numeral` any size w700 + `FontFeature.tabularFigures()` (buffer seconds, counts, durations)

**Shape**: rectangular and sharp. Radii: **8** cards/dialogs, **6** buttons/inputs, **4** chips,
badges, thumbnails, **2** the rail's active indicator bar. Kill every `BorderRadius.circular(999)`
pill. Borders: 1 px hairline everywhere; elevation/shadows/surface tint: none (already the case —
keep). Density: `VisualDensity.compact`; list rows 48 px; 4 px spacing grid (4/8/12/16/24).

**Iconography**: Material outlined set (already shipped), 16–18 px, `textMuted` at rest, `text` on
hover, `accent` only when the element is selected/active. No emoji, no filled duotone.

**States**: hover = `surfaceRaised` fill (no border change), 120 ms ease-out; pressed =
`accentPressed`/darkened fill, no ripple splash spread (set `splashFactory: NoSplash.splashFactory`);
focus = 1.5 px accent border (keyboard only); selected = accent text/icon + 2 px left bar (rail) or
accent border (chips). Disabled = 40% opacity.

**Motion**: 120–150 ms ease-out for hover/selection/chip toggles; 150 ms fade for content-area
destination swaps; nothing else animates. The recording indicator becomes a 10 px solid `rec` dot
with a 1.2 s opacity pulse (0.45→1.0) and **no BoxShadow** — the existing glow in
`status_strip.dart`'s `_PulseDot` is removed. Live-game dots are static mint, no pulse (only the
REC state earns motion).

**ThemeData guidance** (stay on Material widgets where they behave, restyle via theme):
`useMaterial3: true`, override: `splashFactory: NoSplash.splashFactory`, `visualDensity: compact`,
all component shapes to the radii above, `chipTheme` → radius 4 rectangular, `segmentedButtonTheme`
→ radius 6, filled buttons keep mint-on-black. Add a `RewindTokens` `ThemeExtension` (colors +
radii above) in `theme.dart` so custom widgets stop hard-coding `Colors.white.withValues(...)`;
keep the existing `microLabel`/`heroNumeral` `TextTheme` extension, renamed into the scale above.

## 3. Screen specs

Every element lists the existing field feeding it. States are Empty / Loading / Error where relevant;
there is no network, so "loading" only exists where the OS is enumerated (none of these screens block).

### 3.1 Left rail (`widgets/nav_rail.dart`)
- Game rows: union described in §1, fed by `AppSettings.allConfigs`, `ClipLibrary.all` (listen —
  it's a `ChangeNotifier`), `coordinator.activeGameIds` (`ValueNotifier<Set<String>>`, §4 T2).
- Live dot: `activeGameIds.contains(gameId)`. Clip count: count of `library.all` per gameId.
- Empty state (no configs, no clips, nothing active): GAMES section shows only Desktop +
  "+ Add game"; no placeholder art.

### 3.2 Status bar (restyled `widgets/status_strip.dart`)
One 48 px row, left→right: REC/paused indicator + `Buffering · Ns` quick-set (existing wiring) ·
active-game label (`activeGame` → `displayNameFor`) · capture-source menu (existing `_SourceChip`
logic, rectangular) · spacer · `Save clip` filled button (`coordinator.onHotkey`, disabled on
`captureError != null`). Error/permission banner: the existing `_ErrorBanner` (with its macOS
Screen Recording deep-link) renders as a second row under the bar. Chips become radius-4 bordered
rectangles. All existing props (`settingsRevision`, `bufferActive`, `onSettingsChanged`,
`onOpenSettings`) keep their contracts so `status_strip_test.dart` needs restyle-level updates only.

### 3.3 All Clips (`all_clips_screen.dart`, from today's `home_screen.dart` body)
- Header row: "All clips" display text + clip count + total size (sum of `Clip.sizeBytes`) + "Open
  clips folder" icon button (existing `onOpenClipsFolder`).
- Filter row: event-kind chips ("All", then one per `GameEventKind` present in the library, with
  counts) — replaces nothing, adds cross-game event search. The per-game chip rail
  (`game_filter_rail.dart`) is **deleted**: game scoping now lives in the rail (games are
  destinations, not filters).
- List: existing `ClipTile` rows (restyled: radius-4 thumbnail/badge), newest first — unchanged
  data: `event`, `gameId`→`displayNameFor`, `createdAt`→`relativeAge`, `sizeBytes`→`formatSize`,
  overflow menu (open/reveal/delete), tap → Player.
- Empty: existing keycap empty state ("Press ⟨hotkey⟩ to save your last moment"), kept verbatim.
- Save errors: existing `lastSaveError` SnackBar listener moves to the Shell (it must fire on every
  destination, not just All Clips).

### 3.4 Game hub (`game_hub_screen.dart`) — the centerpiece
Layout, top to bottom:
1. **Header**: game name (display), integration status pill, and fact row — clip count, total size,
   "last clip ⟨relativeAge⟩" (all derived from `library.all` filtered to this gameId; omit facts
   when zero clips — no fake stats).
2. **Integration card** (hairline card):
   - `league_of_legends`: label "Live Client API" + state from `activeGameIds`:
     active → mint dot "In match — connected to 127.0.0.1:2999"; inactive → muted dot
     "Waiting for a match. Detection is automatic — start a game and Rewind connects."
     **v0.2 live-event feed slot**: a "LIVE EVENTS" micro-labeled area inside this card that is
     hidden until a `GameEvent` for this gameId arrives on `registry.events` this session; it then
     renders the last ~20 events (badge + `relativeAge`). The Shell passes the coordinator's
     `registry` down; no new plumbing. Until the v0.2 watcher emits, users simply never see it —
     no "coming soon" placeholder text in the card body.
   - `app:*` games: label "Process detection" + "Watching for ⟨processMatch⟩" (from
     `popularGamesCatalog`); active → "Running now". Note line: "No event API for this game —
     clips are hotkey-only." (COMPLIANCE-accurate.)
   - `desktop`: label "Manual capture" + "Clips saved with ⟨hotkey⟩ while no game is detected."
3. **Capture settings card** (inline per-game config, writes via the same
   `settings.configFor(gameId)` → `setConfig` → `onSettingsChanged` path the quick-set uses):
   - Buffer length: 15/30/60/Custom segmented + numeric field (clamp 5–300, mirrors
     settings_screen logic). Feeds `GameConfig.bufferSeconds`.
   - **League only**: "Auto-clip" switch (`GameConfig.autoClip`) and an event matrix — checkbox
     chips grouped COMBAT (kill…ace) / OBJECTIVES (dragon…inhibitor) / MATCH (victory, defeat),
     feeding `GameConfig.enabledEvents`. Group headers are micro labels. `manual` is not shown
     (hotkey always saves). Disable (40%) the matrix when `autoClip` is off.
   - `app:*`/`desktop`: buffer only (they emit no events — hide, don't disable, the event UI).
4. **Clips section**: event-kind filter chips scoped to this game's clips (with counts), then the
   `ClipTile` list. Empty (no clips yet): "No ⟨game⟩ clips yet — press ⟨hotkey⟩ during a game."

### 3.5 Supported games (`supported_games_screen.dart`)
- Grid/list (one column of 56 px rows is fine — 13 entries) of `popularGamesCatalog` + the League
  vendor integration listed first as its own row ("League of Legends — Live Client API: auto-clips
  kills, objectives, wins"; catalog `app:league_of_legends` row is *merged into it* visually — one
  League row showing both detection methods, to avoid a confusing duplicate).
- Per-row state, derived (no new storage): mint dot "Running" (`activeGameIds`), "In your library"
  (has config or clips), or an **Add** button. Add = `settings.configFor(gameId)` +
  `setConfig` + `onSettingsChanged` → the game appears in the rail immediately. Row body:
  `displayName`, detection method ("Process: ⟨processMatch⟩" / "Live Client API").
- Footer note (COMPLIANCE): "Rewind only reads official local APIs and process names — never game
  memory. Games without a sanctioned API get hotkey capture only."
- Empty/error states: none needed (static catalog).

### 3.6 Settings (`settings_screen.dart`, slimmed)
Keeps: default buffer (segmented + custom), capture display dropdown (`displays`), capture app
dropdown (`capturableApps`), hotkey recorder (all existing logic untouched). Adds: "Follow the
game" switch → `AppSettings.autoSwitchCapture` (field exists, has no UI today) with subtitle
"Switch capture to a game's window when it launches". Removes: the Per-game section (now lives in
each hub). Becomes a rail destination instead of a pushed route.

### 3.7 Player (`player_screen.dart`)
Logic unchanged. Header title becomes `displayNameFor(clip.gameId)` + event badge + `relativeAge`
(today it shows the raw gameId string — fix at the `ClipTile._openInApp` call site by passing the
`Clip`). Controls restyled to tokens (radius 6, hairline borders). Esc/space handling kept.

## 4. Build plan

Ordered so `flutter analyze` + `flutter test` pass and the app ships after every task.

**T1 — Tokens + theme rework** (`lib/src/ui/theme.dart`, `lib/src/ui/widgets/status_strip.dart`)
Add `RewindTokens` ThemeExtension (palette + radii §2), retune `rewindTheme()` (density, splash
factory, shapes, deepened bg), rename/extend the TextTheme extension to the §2 scale, de-pill and
de-glow the status strip (remove `_PulseDot` BoxShadow; rectangular chips; 48 px single row +
banner row). Interfaces: `StatusStrip` constructor unchanged. Tests: `test/ui/widgets/
status_strip_test.dart` updated for restyle; `clip_tile_test.dart` if it asserts shapes.

**T2 — Coordinator + directory seams** (`lib/src/coordinator/clip_coordinator.dart`,
new `lib/src/ui/game_directory.dart`)
Add `final ValueNotifier<Set<String>> activeGameIds` to `ClipCoordinator`, updated inside the
existing `registry.activity.listen` block (add on active, remove on inactive; keep `activeGame`
as-is). New pure function `List<GameEntry> buildGameDirectory({required AppSettings settings,
required List<Clip> clips, required Set<String> activeIds})` returning
`GameEntry(gameId, displayName, detection: DetectionMethod{liveClientApi,processWatch,manual},
processMatch, active, clipCount, totalSizeBytes, lastClipAt)` with the §1 union/sort rules and the
League/`app:league_of_legends` merge (§3.5). Tests: extend `test/clip_coordinator_test.dart`
(activity → set transitions); new `test/game_directory_test.dart`.

**T3 — Shell + rail + All Clips** (new `lib/src/ui/shell.dart`, `widgets/nav_rail.dart`;
`home_screen.dart` → `all_clips_screen.dart`; `lib/main.dart` rewire; delete
`widgets/game_filter_rail.dart`)
Shell owns: destination state, the status bar, the `lastSaveError` SnackBar listener, and passes
`coordinator`/`library`/`registry`/`displays`/`capturableApps`/`onSettingsChanged`/
`settingsRevision`/`onOpenClipsFolder`/`hotkeyLabel` down. All Clips gains the event-kind chip row.
Settings/Logs open from the rail (Settings still a pushed route in this task — becomes embedded in
T5). Tests: `test/ui/home_screen_test.dart` → `shell_test.dart` + `all_clips_screen_test.dart`
(filter pruning test moves to the event-chip behavior; game-filter tests are deleted with the rail).

**T4 — Game hub** (new `lib/src/ui/game_hub_screen.dart`, `widgets/event_filter_chips.dart` shared
with All Clips)
Implements §3.4 including the live-events slot (a `StreamBuilder`-fed, session-scoped ring buffer of
`registry.events` filtered by gameId, hidden while empty). Per-game settings write through
`onSettingsChanged`. Tests: new `game_hub_screen_test.dart` (integration states per detection
method, event matrix → `GameConfig.enabledEvents`, chips filter the list, live-slot hidden/shown).

**T5 — Supported games + Settings slim-down** (new `lib/src/ui/supported_games_screen.dart`;
`settings_screen.dart`)
§3.5 catalog with Add flow; remove the Per-game section from Settings, add the `autoSwitchCapture`
switch, embed Settings as a rail destination. Tests: `settings_screen_test.dart` updated (per-game
section assertions removed, auto-switch toggle added); new `supported_games_screen_test.dart`
(Add creates a config row; states render from directory input).

**T6 — Player + polish pass** (`player_screen.dart`, `widgets/clip_tile.dart`)
Player header per §3.7 (pass the `Clip` through), token-align remaining hard-coded colors/radii,
empty-state copy sweep. Tests: `player_screen_test.dart` (route-name assertions unchanged),
`clip_tile_test.dart` title/navigation args.

Docs (same change as T5 or T6): README screenshot/description, ROADMAP v0.2 note that the UI slot
for the League watcher exists, CHANGELOG "Unreleased".

## 5. Explicitly out of scope / YAGNI
No thumbnails pipeline, no free-text search (clips have no text fields — event chips are the
search), no per-game "playtime/stats" (no data), no pin UI (StorageManager UI is v0.3), no router
or state-management packages, no bundled fonts, no light theme.
