# Rewind

**Open-source, cross-platform instant-replay and automatic game-clip capture for Windows and macOS.**

Rewind keeps a rolling buffer of your last N seconds of gameplay in memory and saves a clip the moment something worth keeping happens — either when you press a hotkey, or automatically when your game reports an in-game event (a kill, an ace, a dragon steal). It's the ShadowPlay / Medal-style experience that Windows has always had, brought to macOS too, in a single app.

> Status: **early scaffold / pre-alpha.** The architecture and docs are in place; the capture engine and event integrations are being built. See [ROADMAP.md](ROADMAP.md).

---

## Why Rewind exists

On Windows, gamers have NVIDIA Instant Replay, Medal.tv, and Outplayed — background recorders that auto-clip highlights. On macOS almost none of this exists, and the tools that do (ClipMac, RetroClip, MacClipper) are manual-hotkey only, with no automatic in-game event detection. Rewind closes that gap with one codebase that runs on both platforms.

## How it works

Rewind is a **Flutter** desktop app (shared UI + logic) sitting on top of an **embedded [libobs](https://github.com/obsproject/obs-studio) capture engine** (the same battle-tested core that powers OBS Studio). libobs handles efficient screen capture, hardware video encoding, and the in-memory replay buffer. Rewind drives it through a small **C shim** exposed to Dart via `dart:ffi`.

```
+-------------------------------------------------------------+
|  Flutter (Dart) — UI, settings, clip library, hotkeys       |
|  + Event watchers (e.g. League Live Client Data API @2999)  |
+---------------------------+---------------------------------+
                            | dart:ffi
+---------------------------v---------------------------------+
|  Rewind C shim (native/shim) — thin, stable C API           |
+---------------------------+---------------------------------+
                            | C
+---------------------------v---------------------------------+
|  libobs — capture, hardware encode, replay ring buffer      |
+-------------------------------------------------------------+
```

When a game event fires (or you hit the hotkey), Dart calls `rewind_save_clip()` and libobs flushes the last N seconds to an `.mp4`.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Features (planned)

- Rolling replay buffer (RAM-backed) on Windows and macOS
- **Manual hotkey clip** ("clip that") that saves the last **30s / 60s / custom** — configurable **per game**
- **Automatic game detection** — Rewind notices which game is running and applies that game's settings
- **Automatic event-based clipping** — starting with League of Legends via the local Live Client Data API (kills, multikills, aces, dragon/baron, turrets)
- Clip library with tagging by event type
- Hardware-accelerated encoding (NVENC / AMF / Apple VideoToolbox via libobs)
- Menu-bar / tray background operation

## Supported games (event auto-clipping)

| Game | Method | Status |
|------|--------|--------|
| League of Legends | Live Client Data API (`127.0.0.1:2999`) — official, read-only, anti-cheat safe | Planned (v0.2) |
| Any game (incl. MECCHA CHAMELEON & other mech/action titles) | Manual hotkey capture — always safe | Planned (v0.1) |
| More titles | Per-game integrations (sanctioned sources only) | Future |

Initial test targets are **League of Legends** (event auto-clipping via the
official local API) and a second title, **MECCHA CHAMELEON** (a mech action game), which
runs in **manual-hotkey mode** unless the vendor exposes a sanctioned event
source. See [docs/COMPLIANCE.md](docs/COMPLIANCE.md).

## Building

Requires the Flutter SDK (desktop enabled). The native C shim is compiled and
bundled automatically by a Dart **build hook** (`hook/build.dart`) — no per-OS
build files to manage. Linking real libobs is described in
[native/shim/README.md](native/shim/README.md). Full setup in
[CONTRIBUTING.md](CONTRIBUTING.md).

```bash
flutter pub get
flutter run -d macos      # or: flutter run -d windows
```

## Legal & safety

Rewind is designed to be **ToS-friendly and anti-cheat safe**: game integrations
use only **sanctioned data sources** (official local APIs, logs, or SDKs) or
plain screen capture — **never** memory reading, injection, or hooking. Games
without an official API are supported in manual-hotkey mode only. See
[docs/COMPLIANCE.md](docs/COMPLIANCE.md). (Not legal advice.)

## License

Rewind is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE). GPLv3 is required because Rewind embeds libobs, which is GPL-licensed. This means Rewind is and will remain free and open source.

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the [ROADMAP.md](ROADMAP.md) for where help is most useful.
