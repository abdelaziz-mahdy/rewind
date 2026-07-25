# Broadcast Deck — design system v2 — spec

Date: 2026-07-25. Status: approved for implementation (maintainer picked "Direction A" from the
2026-07-25 UI/UX audit).
Scope: UI only. Capture pipeline, coordinator, settings model and their tests stay intact. No new
FFI surface, no new packages.

Supersedes the visual half of `2026-07-13-game-centric-redesign.md` (§2 palette/type). Its shape
rules — no pills, no gradients, no glow, no shadows, hairlines carry hierarchy — are KEPT and
extended, not replaced. Its IA (rail + sealed `ShellDestination`) is unchanged.

## 0. The one rule

**Hue is reserved for state. Chrome is achromatic.**

If something on screen carries a hue, it means the machine is doing something. Navigation,
selection, primary buttons, focus rings and every other interaction affordance are painted in a
neutral steel. This is the entire fix for audit finding F-01 (one mint meaning seven things) and it
is enforced structurally: after §1 there is no single `accent` token to reach for, so painting a nav
row with a state color requires importing the wrong token on purpose.

Reference for what each hue is allowed to mean:

| Token | Value | Means, and means ONLY |
|---|---|---|
| `interactive` | `#DCE3EC` | Selection, primary fill, focus ring, active segment. Carries no state. |
| `armed` | `#F5A524` | The buffer is running / a game is live / auto-clip is on. Broadcast standby tally. |
| `onAir` | `#FF4D4F` | A manual recording is actively running. Nothing else. |
| `positive` | `#37D39B` | Match outcome (WIN) and kill counts. The old mint, demoted to one job. |
| `danger` | `#E5484D` | Destructive confirmation and capture errors. Distinct from `onAir` on purpose — "you are recording" and "this will delete a file" must not be the same red. |
| `warn` | `#F5A524` | Permission/error banner. Same value as `armed`; separate name because they are separate concepts and may diverge. |
| `eventSeed` | `#F0B429` | The base hue every event-badge color is rotated from (see §1.3). |

### 0.1 Why this is not the deck we deleted

`2026-07-13-game-centric-redesign.md` §3.2 shipped a full-width `StatusStrip` deck; the maintainer
removed it as "redundant", because it restated what the rail and each hub header already said (which
game is active, its name, its icon). That judgement was correct for THAT deck.

This deck carries only what nothing else in the app can say:

- **tally state** — armed / on-air / unavailable, as a broadcast tally light
- **buffer fill** — a ring showing how much of the rolling buffer is actually held right now
- **timecode** — buffer length, or elapsed recording time while on-air
- **capture target** — what a save would actually record
- **the two verbs** — Save clip / Record, plus the hotkey that does the same thing

None of that appears anywhere else, and per audit F-02/F-03 the current home for it (bottom of the
nav rail) both buries it and loses it entirely on the Settings destination.

## 1. Tokens

### 1.1 Color

`RewindTokens` keeps its shape. `accent`/`accentPressed`/`rec` are renamed and joined by new roles:

```
bg              #0C0E11 -> #08090B
surface         #14171C -> #101216
surfaceRaised   #1A1E24 -> #181B21
hairline        0x14FFFFFF (unchanged)
text            #E6EAEF -> #E8EBEF
textMuted       #8B94A1 -> #7C8797
textDim         (new)      #525C6B     -- micro-labels; stops them fighting body copy for one grey
accent          #3DDC97 -> REMOVED
accentPressed   #2FB37C -> REMOVED
interactive     (new)      #DCE3EC
interactivePressed (new)   #B9C4D2
armed           (new)      #F5A524
onAir           #FF4757 -> #FF4D4F   (renamed from `rec`, meaning narrowed)
positive        (new)      #37D39B
danger          (new)      #E5484D
warn            #FFB74D -> #F5A524
eventSeed       (new)      #F0B429
```

Radii are unchanged (8 / 6 / 4 / 2) — the audit found them already correct.

**Contrast gate.** The 2026-07-20 note on `RewindTokens` stands: every foreground token must clear
WCAG AA (4.5:1) against `bg`, `surface` and `surfaceRaised`. A test (`test/theme_contrast_test.dart`)
now enforces this instead of a comment, so a future retune cannot silently go sub-AA.

`interactive #DCE3EC` is a near-white fill; the primary button's foreground flips to `bg` (near
black) for a ~15:1 pair. `textDim #525C6B` is only ever used on `bg`/`surface` for micro-labels at
w700 — it clears 4.5:1 on both.

### 1.2 Type

`pubspec.yaml` bundles no fonts today, so the UI renders in SF Pro on macOS and Segoe UI Variable on
Windows — two different designs from one codebase (audit F-04). Three OFL families ship in
`assets/fonts/`:

| Role | Family | Used for |
|---|---|---|
| Display | **Archivo** (600/700/800) | Screen titles, hub names, card headlines |
| UI | **Inter Tight** (400/500/600/700) | All body copy, labels, buttons, settings rows |
| Numeral | **IBM Plex Mono** (500/600) | Timecode, durations, sizes, K/D/A, buffer seconds, clip counts, hotkey caps |

`RewindTypography` gains `numeral` as a real mono style; every existing
`FontFeature.tabularFigures()` call site switches to it. Micro-labels stay uppercase/tracked but move
to Inter Tight 600 (Archivo's tracking is too tight at 11px).

OFL is GPLv3-compatible; each family's `OFL.txt` ships alongside it in `assets/fonts/` and is listed
in `docs/THIRD_PARTY.md`.

### 1.3 Event colors

`eventColor()` currently derives every badge hue by HSL-rotating `colorScheme.primary` — which will
be achromatic steel after §1.1, so rotation would produce grey. Event hues re-base on
`RewindTokens.eventSeed` (`#F0B429`, saturated amber):

- combat ladder (kill -> penta): `eventSeed` with saturation/lightness climbing per tier (unchanged math, new base)
- achievement: `eventSeed` rotated to gold (hue 48)
- objectives (dragon/baron/turret/inhibitor): `eventSeed` rotated to violet (hue 266)
- victory: `positive`; defeat/death: `danger`; manual/recording: `textMuted` (an operator action, not a game moment)
- metadata kinds: `textDim`

`manual` moving off the accent is deliberate: a hotkey save is not a highlight, and painting it with
the same hue as a pentakill was the library's loudest lie.

### 1.4 Motion

Unchanged budget — **zero idle animation** (the `_PulseDot` CPU story in `recorder_cluster.dart`
stands; nothing may animate while the app sits in the background).

- destination change: 160 ms slide + fade, directional (forward = from below, back = from above)
- hover/press: 90 ms
- state change (tally flip, buffer ring): 220 ms, ease-out
- `MediaQuery.disableAnimations` respected everywhere

## 2. The transport deck

A new `TransportDeck` widget, 44 px tall, rendered by `Shell` ABOVE the `Row(rail, content)` — so it
spans the full window and is present on every destination **including Settings** (audit F-03).

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ● ARMED  ◔ 00:30 BUFFER │ ▭ League Of Legends ⌄ │   ⌥F10  [Save clip] [● Record] │
├──────────┬─────────────────────────────────────────────────────────────────┤
│  REWIND  │                                                                 │
│ ALL CLIPS│                        CONTENT                                  │
│ GAMES    │                                                                 │
│ ● League │                                                                 │
```

Left to right:

1. **Tally** — `ARMED` (amber) while the buffer runs, `REC m:ss` (red) while manually recording,
   `UNAVAILABLE` (danger) on capture error, `WAITING FOR A GAME` (dim) when auto-paused by
   `captureOnlyInGame`, `PAUSED` (dim) when paused from the tray.
2. **Buffer ring + timecode** — a conic ring filling as the rolling buffer fills, and the buffer
   length in mono. While recording, the ring is replaced by elapsed time. Ring fill comes from a new
   read-only `ClipCoordinator.bufferFillFraction` seam (see §5) — it must never require a new FFI
   call per frame.
3. **Source** — the existing `_SourceLine` picker, moved verbatim out of `RecorderCluster`.
4. **Hotkey cap + Save clip + Record** — the existing controls, moved. `Save clip` is the app's one
   primary fill and is therefore `interactive` (near-white on near-black).

`RecorderCluster` is deleted; `NavRail` becomes navigation only and loses `captureError`,
`bufferActive`, `bufferAutoPaused`, `displays`, `capturableApps`, `listApps`, `onSettingsChanged`.
Those props move to `TransportDeck`. `Shell` keeps its existing prop list unchanged — only where it
forwards them changes — so `main.dart` needs no edit.

The deck is NOT shown during onboarding (there is nothing to transport yet).

## 3. Screen changes

### 3.1 Game hub

- Status pill copy stops naming the implementation (audit F-06):
  `LIVE CLIENT API` -> `IN MATCH · CLIPS ITSELF` / `READY · CLIPS ITSELF`
  `PROCESS DETECTION` -> `RUNNING · KNOWS WHEN YOU PLAY` / `KNOWS WHEN YOU PLAY`
  `MANUAL CAPTURE` -> `HOTKEY ONLY`
  The pill is `armed` when the game is live, `textDim` otherwise.
- A four-cell **score band** replaces the header's fact line: matches, win rate, average KDA, disk.
  Win rate and KDA only appear for a game that has recorded stats; a process-only game shows
  sessions / clips / disk / last clip instead. No invented stats — every cell is derived from
  `MatchStatsStore` + `ClipLibrary` data already on hand, and a cell with no data is omitted rather
  than shown as zero.
- The capture-settings summary collapses from a two-line card to one row.

### 3.2 All Clips / hubs — one session card

Both screens render sessions through the same `SessionCard` (promoted from `widgets/match_card.dart`),
so the two aspect ratios (`clipGridChildAspectRatio` vs `matchCardAspectRatio`) collapse to one
(audit F-05). All Clips keeps its cross-game feed grouping; the hub keeps its per-game grid; only the
card is shared.

All Clips header gains a sort control (newest / largest / longest). Grid density follows window
width: `clipGridMaxCrossAxisExtent` becomes a function of available width (300 -> 380 above 1600 px)
rather than a constant (audit F-09).

### 3.3 Player

- Seek track 3 px -> 5 px, fill `interactive`, so event markers own the only hues on the bar.
- Markers gain a labelled legend row beneath the track (`▲ KILL 0:06`), which also gives the markers
  a text alternative for screen readers.
- Header names the moment (`Penta Kill · SINGED · ARENA · 2 H AGO`) instead of "Clip".

### 3.4 Empty library

Teaches the buffer instead of describing it: an `ARMED — RECORDING THE LAST 30 SECONDS` line in
`armed`, a static diagram of the rolling window with `NOW` at its right edge, the hotkey, and two
actions (Add a game / Open clips folder). Static — no animation (§1.4).

### 3.5 Save confirmation

The stock `SnackBar('Clip saved')` becomes a `ClipSavedToast`: thumbnail, event name, duration, and a
"Show me" action that navigates to the clip (audit F-08). Still auto-dismisses in 3 s, still uses
`ScaffoldMessenger` so nothing about the call site changes.

## 4. Accessibility

`grep -rn "Semantics(" lib/src/ui` returns 0 today (audit F-07). Every state signal that is currently
color-only gets a text alternative, added as each widget is touched:

- tally dot + label -> `Semantics(label: 'Buffer armed, 30 second buffer')`
- rail live dot -> `Semantics(label: '<game> is running')`
- rail clip count -> `Semantics(label: '<n> clips')`
- K/D/A badge -> `Semantics(label: '8 kills, 3 deaths, 11 assists')`
- WIN/LOSS badge, event badges, buffer ring -> labelled
- minimum control height 32 px in banners (audit F-11); `MaterialTapTargetSize.shrinkWrap` removed
  from the detected-game banner's Record button

A widget test asserts the tally and the rail's live dot expose labels, so this does not regress.

## 5. Seams touched outside `lib/src/ui`

Exactly one, additive:

- `ClipCoordinator.bufferFillFraction` — a `ValueListenable<double>` in `[0,1]`, updated on the
  existing buffer-state cadence (not per frame), used by the deck's ring. When the engine cannot
  report it, the listenable stays at `1.0` and the ring renders full, which is the honest reading for
  a buffer that has been running longer than its own length.

Everything else is UI-local.

## 6. Order of work

Each step is independently shippable and independently reviewable.

1. **Token role split** — rename/add tokens, fix every call site, re-base `eventColor`, add the
   contrast test. No visual restructuring.
2. **Fonts** — bundle the three families, point `RewindTypography` at them, add `numeral`.
3. **Transport deck** — extract `TransportDeck`, delete `RecorderCluster`, render it on every
   destination including Settings. Add `bufferFillFraction`.
4. **Session card unification** + grid density + sort.
5. **Copy + Semantics + save toast** — status pills, empty states, labels.
6. **Polish** — one icon family (outlined), control heights, directional transitions, title-bar drag
   region.

## 7. Non-goals

- No light theme. `RewindTokens.dark` remains the only instance.
- No router or state-management package.
- No new capture behavior, no new detection sources, no new FFI.
- No per-game theming (that was Direction B, not chosen).
