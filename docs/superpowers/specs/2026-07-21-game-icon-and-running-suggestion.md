# Real game icons + "running now" suggestions

Date: 2026-07-21

## Problem

Steam/Wine games (e.g. R.E.P.O. run through CrossOver) have **no macOS
`.app` bundle**, so `AppInfo.iconPath` is empty and the UI falls back to a
two-letter placeholder tile ("RE"). Users can't recognize the game. The
macOS Dock shows the real orange-robot icon, but that icon is set at
runtime by Wine and is **not** reachable through `NSRunningApplication.icon`
(verified 2026-07-21: that API returns the generic green "exec" icon for
the Wine pid).

Separately, an unadded-but-running game only appears buried in Supported
Games → "Running now". The home screen's `_DetectedGameBanners` suggests
only **catalog** games, so a Wine game like R.E.P.O. is never surfaced as
"want to record this?".

## Verified facts (2026-07-21, live)

- `NSRunningApplication(processIdentifier: REPO.exe pid).icon` → generic
  "exec" icon. Dead end.
- The real icon lives on disk in Steam's cache:
  `…/Steam/appcache/librarycache/<appid>/` — a loose small square `<hash>.jpg`
  (the icon, ~800 B, confirmed = robot) plus `library_600x900.jpg` (capsule),
  `logo.png`, `library_header.jpg`.
- Mapping exe → appid is deterministic:
  - process command (`ps -axo comm=` / shim window owner) gives the Windows
    path `C:\…\steamapps\common\REPO\REPO.exe` → install dir `REPO`.
  - `steamapps/appmanifest_*.acf` whose `"installdir"` == `REPO` →
    `"appid" "3241660"`, `"name" "R.E.P.O."`.
- On macOS the Windows path maps into a CrossOver bottle under
  `~/Library/Application Support/CrossOver/Bottles/*/drive_c/…`. On native
  Windows/Linux the Steam path is a real filesystem path already.

## Design

### 1. `SteamIconResolver` (pure Dart, cross-platform)

New seam `lib/src/games/steam_icon_resolver.dart`. Input: a running app's
command/exe path string. Output: `SteamGameArt? { String appId, String name,
String iconPath }` or null.

Steps (all `dart:io`, no native code):
1. Find `steamapps[/\\]common[/\\]<installDir>[/\\]` in the path → `installDir`.
2. Resolve the on-disk `steamapps` dir:
   - native Win/Linux: the literal dir in the path.
   - macOS: translate the `C:\…` path into a bottle by scanning
     `~/Library/Application Support/CrossOver/Bottles/*/drive_c/` for the
     matching `steamapps` subpath (memoized).
3. Read `appmanifest_*.acf`, tiny VDF parse for `"installdir"` == installDir
   (case-insensitive) → `appid`, `name`.
4. Icon file, first that exists under `appcache/librarycache/<appid>/`:
   the single loose `*.jpg` directly in that dir (square icon) → else any
   `**/library_600x900.jpg` (capsule) → else `**/logo.png`.
5. Copy the chosen file into Rewind's icon cache
   (`<clipsDir>/.thumbs/steam-<appid>.<ext>`) once; return that stable path.

Memoize by appid. Fail soft (return null) on any missing piece — never throw.

Reused for both display **name** ("R.E.P.O." beats "REPO") and icon.

### 2. Window-frame fallback (native, STAGED — needs a build)

When the Steam lookup misses and the app's window is on-screen, grab one
frame of that window, downscale, cache as the tile. New shim call
`rewind_snapshot_window(window_id, out_path)` (ffigen-generated binding,
per project rule), implemented mac/Windows/Linux. Deferred to its own
commit because the data volume is currently 100% full and the native shim
can't be built/verified. Until then the fallback is simply the existing
letter tile. Documented as such.

### 3. Icon plumbing into the UI

- Extend the app→game learning + `AppInfo` presentation so a resolved Steam
  art path flows to `GameTileAvatar`. Preferred: resolve lazily in the
  widget layer via a small `GameArtCache`/seam keyed by app identity, so the
  enumeration stays cheap and the resolver runs only for rows actually shown.
- `learnAppAsGame` uses the resolved name + iconPath when present (so adding
  R.E.P.O. stores the robot icon and proper name).

### 4. Home suggestion banner for unadded running games

Extend `_DetectedGameBanners` (`shell.dart`) so, in addition to catalog
games in `activeGameIds`, it surfaces **capturable running apps that are not
yet added** — the same `partitionCapturableApps(listApps())` filtered set
used by "Running now", limited to the probable-games partition (Wine exes /
catalog matches), deduped against configured ids and session-dismissed ids.
Each banner shows the resolved icon + name and a Record action that runs the
existing add-then-point-capture flow. Cap at 1–2 to avoid a wall of banners;
keep the dismiss-X.

### 5. Cross-platform + docs

- Steam resolver handles Win/macOS(CrossOver)/Linux path forms; documented.
- Window-frame shim: mac + Windows + Linux (staged).
- Update CHANGELOG; note Steam-icon support in README supported-games text.

## Storage / retention

Cached icons are tiny and live in `.thumbs`; no retention change.

## Testing

- `SteamIconResolver`: hermetic — build a fake steam tree in a temp dir
  (appmanifest + librarycache files), assert appid/name/icon resolution,
  case-insensitive installdir, missing-pieces → null, memoization. macOS
  bottle translation via an injected bottles-root.
- Running-now + banner: widget tests assert a resolved icon path reaches the
  avatar (fake resolver), and that an unadded running game yields a banner
  while an added/dismissed one does not.
- No native (frame-grab) tests until that stage builds.

## Sequencing (atomic commits, buildable-first given full disk)

1. `SteamIconResolver` + tests (pure Dart).
2. Icon plumbing → Running-now real icons + tests.
3. Home banner extension for unadded running games + tests.
4. (Staged) window-frame fallback shim + ffigen + wiring, once disk freed.
