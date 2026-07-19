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
- **Steam (achievement auto-clip):** `SteamAchievementWatcher` uses ONLY the
  official Steam Web API (`api.steampowered.com`) — `GetPlayerSummaries`
  (which appid the user is playing), `GetPlayerAchievements` (unlocked
  flags/timestamps), `GetSchemaForGame` (achievement display names), and
  `ResolveVanityURL` (vanity name → SteamID64). No memory access, no
  process hooking, no packet capture — same rule as every other
  integration. The user supplies their own Steam Web API key
  (steamcommunity.com/dev/apikey) and SteamID64; both are stored locally in
  `settings.json` only and sent nowhere but `api.steampowered.com` as query
  params, per that API's own auth scheme. This works for EVERY Steam game
  (not one title at a time, unlike League) because it reads Steam's own
  account-level achievement data rather than anything game-specific — the
  achievement's game itself never has to sanction anything separately. The
  user's Steam profile must have "Game details" set to Public (a Steam
  privacy setting) for `GetPlayerAchievements` to return data at all; the
  Settings → Steam page's status line reports this plainly when it isn't.
- **Games without an official API (e.g. many mech/action titles):** ship as
  **manual-hotkey capture only** until/unless the vendor provides a sanctioned
  event source. Do not add memory/hook-based detection.

## Checklist for a new integration PR

- [ ] Data comes only from a sanctioned source (API/log/SDK) or is manual-only.
- [ ] No memory reads, injection, hooking, or packet capture.
- [ ] Handles the source being unavailable gracefully.
- [ ] Notes any vendor terms that apply, in the integration's doc comment.
