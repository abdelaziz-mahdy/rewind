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

## Per-game notes

- **League of Legends:** integration uses only the official Live Client Data
  API. No memory access. Riot's developer terms apply to any use of Riot data;
  we stay within the local, read-only API.
- **Games without an official API (e.g. many mech/action titles):** ship as
  **manual-hotkey capture only** until/unless the vendor provides a sanctioned
  event source. Do not add memory/hook-based detection.

## Checklist for a new integration PR

- [ ] Data comes only from a sanctioned source (API/log/SDK) or is manual-only.
- [ ] No memory reads, injection, hooking, or packet capture.
- [ ] Handles the source being unavailable gracefully.
- [ ] Notes any vendor terms that apply, in the integration's doc comment.
