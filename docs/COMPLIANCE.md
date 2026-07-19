# Legal & anti-cheat compliance

> This document is engineering guidance, **not legal advice**. Rewind
> contributors are not lawyers. When in doubt about a specific game, read that
> game's Terms of Service / EULA and, for anything commercial, consult a
> professional.

Rewind's goal is to be a **safe, ToS-friendly** recorder that never risks a
user's account. The design follows a few hard rules.

## The core rule: sanctioned data sources only

A game integration (`GameEventSource`) may ONLY obtain event data from sources
the game vendor sanctions:

1. **Official local APIs.** e.g. League of Legends' **Live Client Data API** on
   `127.0.0.1:2999`. Riot ships this specifically for third-party apps; it is
   read-only, localhost-only, and does **not** touch game memory — so it is
   anti-cheat safe and allowed.
2. **Official log files / telemetry** the game writes to disk for the user.
3. **Vendor-provided SDKs / event APIs** (e.g. an official overlay/GEP-style
   API) where the vendor permits it.
4. **Screen capture of your own gameplay**, which is what libobs does.

**Never** do any of the following — they can violate ToS and/or trip
kernel-level anti-cheat (Vanguard, EAC, BattlEye, etc.) and get users banned:

- Reading or writing game process memory.
- DLL injection / API hooking into the game process.
- Packet inspection of the game's network traffic.
- Anything that modifies the game or its files.

If a game exposes no sanctioned event source, Rewind falls back to
**manual-hotkey capture only** (screen recording), which is universally safe.

## Screen recording itself

Recording video of your own screen/gameplay for personal use is generally fine
and is what every mainstream capture tool (OBS, ShadowPlay, Medal) does. Two
caveats to keep in mind:

- **Redistribution** of captured footage (uploading, streaming) is subject to
  the game's content policy and copyright. Rewind captures; how a user shares is
  on them. We surface this in-app where relevant.
- **Other people's content / private info** may appear on screen; that's a user
  responsibility, but we avoid uploading anything without explicit user action.

## Riot's required legal boilerplate (do not remove)

Riot's [Developer API Policy](https://developer.riotgames.com/docs/lol)
requires this text, **verbatim**, "in a location that is readily visible to
players" for any product using their APIs or game-specific static data. Rewind
reads the Live Client Data API and renders Data Dragon art, so it applies:

> Rewind is not endorsed by Riot Games and does not reflect the views or
> opinions of Riot Games or anyone officially involved in producing or managing
> Riot Games properties. Riot Games and all associated properties are
> trademarks or registered trademarks of Riot Games, Inc.

It lives in `kRiotDisclaimer` (`lib/src/ui/system_settings.dart`) and is shown
in **Settings → About & help**; a test asserts it renders. Do not reword,
shorten, or hide it.

Two more policy points that bind this project:

- **Riot IP:** only the Press Kit and **game-specific static data** may be
  used. Data Dragon champion/item art is game-specific static data, so it is
  allowed; do not ship other Riot logos/artwork. This also covers art never
  "shipped" but read at runtime: the rail's real-app-icon feature
  (`GameConfig.iconPath`, `GameTileAvatar`) deliberately excludes League —
  its app icon IS Riot's official logo — via `usesOfficialLogo` in
  `lib/src/ui/capture_app_match.dart`. Do not remove that exclusion to "fix"
  a missing rail icon.
- **No win rates for Augments or Arena Mode items** — an explicitly
  unapproved use case. Showing the player their *own* picks is fine;
  aggregate/win-rate stats for augments or Arena items are not.
- **Registration:** a product that serves players must be registered on
  Riot's Developer Portal, even when it only uses local APIs. That is a
  maintainer action, tracked in ROADMAP.

## Per-game notes

- **League of Legends:** integration uses only the official Live Client Data
  API. No memory access. Riot's developer terms apply to any use of Riot data;
  we stay within the local, read-only API.
- **VALORANT** (research verdict 2026-07-19): **manual-hotkey capture only,
  permanently** — not "until a vendor API lands." Riot's developer policy
  (developer.riotgames.com/docs/valorant; the Riot policy disclaimer above
  covers all Riot titles) restricts real-time match data for this game, so
  there is no sanctioned event source to integrate even in principle. Also
  **Windows-only**: Vanguard, Riot's kernel-level anti-cheat, blocks every
  VM/CrossOver capture path outright, unlike Wine-friendly titles.
- **Marvel Rivals** (research verdict 2026-07-19): **manual-hotkey capture
  only** — no sanctioned real-time source exists. There is no public
  match/event API, and the game's own client logs are encrypted, so even an
  "official log file" integration (rule 2 above) is unavailable. Process
  detection only, matching the game binary
  (`Marvel-Win64-Shipping`) — never the launcher, which runs outside matches.
  Works on Windows natively and on macOS via CrossOver (NetEase ships no
  kernel-level anti-cheat that blocks Wine the way Riot's Vanguard does for
  VALORANT). `GameDescriptor.usesOfficialLogo` is conservatively `false`:
  Marvel/Disney/NetEase publish no fan-tool logo carve-out the way Riot's
  policy explicitly does, so the rail/hub never show its real app icon.
- **Steam (achievement auto-clip, maintainer decision 2026-07-19):**
  `SteamStatsWatcher` detects unlocks entirely from files Steam's OWN client
  already writes to the user's own disk for its own use —
  `appcache/stats/UserGameStats_<accountId3>_<appid>.bin` (an
  `AchievementTimes` index → unix-timestamp map, updated seconds after every
  real unlock) and the sibling `UserGameStatsSchema_<appid>.bin` (achievement
  display names). This is rule 2 above ("official log files / telemetry the
  game" — here, the Steam client itself — "writes to disk for the user"):
  Rewind only ever OPENS and READS these files, on a plain `stat()`/read
  cadence, exactly like watching a log file grow. No memory access, no
  process hooking, no injection, no packet capture, and — the one rule
  specific to this integration — **Rewind must NEVER write to any file under
  a Steam install's `appcache/` or `userdata/` trees, under any
  circumstance.** Writing there is Steam's job alone; a third-party writer
  risks corrupting the client's own cache.

  The file format itself (binary VDF / KeyValues) is UNDOCUMENTED by Valve,
  but has been stable for roughly a decade, is the same format multiple
  long-running open-source tools already parse this same way (e.g.
  Achievement Watcher, Steam Achievement Manager — prior art, not copied
  code; see `steam_stats_vdf.dart`'s doc), and — being a read-only local
  file, not a network protocol — a Rewind version that guesses a field wrong
  degrades to "no display name" or "no detection," never a crash, a ban
  risk, or corrupted Steam state.

  Unlike the retired Web API design this replaces, NO credentials are
  needed: the watcher discovers every Steam install ("tree" — native, plus
  every independent CrossOver bottle) on this machine itself, reading each
  tree's own `config/loginusers.vdf` (already used by `steam_account_
  locator.dart` for onboarding) to find its logged-in account id3(s), then
  watches every tree simultaneously. This works for EVERY Steam game (not
  one title at a time, unlike League) for the same reason the retired
  design did: it reads Steam's own account-level achievement data, not
  anything game-specific — the achievement's game itself never has to
  sanction anything separately, and there is no "Game details must be
  Public" privacy requirement either (that was specific to the Web API this
  no longer calls).

  The Web API integration (`SteamAchievementWatcher`, `api.steampowered.
  com`) stays in the tree, compiling and tested, but is no longer
  constructed by `source_builder.dart` — kept only as a seam for possible
  future enrichment. If it's ever re-enabled, its own rules still apply
  unchanged: user-supplied key + SteamID64, both local-only, sent nowhere
  but `api.steampowered.com`.
- **Games without an official API (e.g. many mech/action titles):** ship as
  **manual-hotkey capture only** until/unless the vendor provides a sanctioned
  event source. Do not add memory/hook-based detection.

## Checklist for a new integration PR

- [ ] Data comes only from a sanctioned source (API/log/SDK) or is manual-only.
- [ ] No memory reads, injection, hooking, or packet capture.
- [ ] Handles the source being unavailable gracefully.
- [ ] Notes any vendor terms that apply, in the integration's doc comment.
