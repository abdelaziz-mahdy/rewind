# Third-party assets and their licenses

Rewind is GPLv3 (mandatory — libobs is GPL). Everything bundled here must be
GPLv3-compatible. This file lists what ships inside the app that Rewind did
not write; Dart package dependencies are listed in `pubspec.yaml` and their
licenses are surfaced by Flutter's own `showLicensePage`.

## Fonts

Three families ship in `assets/fonts/`, all under the **SIL Open Font License
1.1**, which is GPL-compatible and imposes no restriction on the licensing of
the software that embeds the font.

| Family | Files | Upstream | License |
|---|---|---|---|
| Archivo | `Archivo-Variable.ttf` | [google/fonts · ofl/archivo](https://github.com/google/fonts/tree/main/ofl/archivo) | `assets/fonts/OFL-Archivo.txt` |
| Inter Tight | `InterTight-Variable.ttf` | [google/fonts · ofl/intertight](https://github.com/google/fonts/tree/main/ofl/intertight) | `assets/fonts/OFL-InterTight.txt` |
| IBM Plex Mono | `IBMPlexMono-{Regular,Medium,SemiBold}.ttf` | [google/fonts · ofl/ibmplexmono](https://github.com/google/fonts/tree/main/ofl/ibmplexmono) | `assets/fonts/OFL-IBMPlexMono.txt` |

The three `OFL-*.txt` files are declared as app assets (see `pubspec.yaml`),
so the license travels inside every built binary, not just in this repo.

Why these three: see
`docs/superpowers/specs/2026-07-25-broadcast-deck-design-system.md` §1.2.
Short version — with no bundled fonts the UI rendered in SF Pro on macOS and
Segoe UI Variable on Windows, which is two different designs from one
codebase, and a type scale that can only ever be tuned for one of them.

**Reserved Font Names:** none of the three declare an RFN, so the files may be
redistributed under their original names. If a family is ever subsetted or
modified, keep the OFL text with it and do not remove the copyright notice.

## Native

| Component | Where | License |
|---|---|---|
| libobs (OBS Studio core) | fetched into git-ignored `native/third_party/obs/` by `tools/fetch_libobs.sh`, bundled at package time | GPLv2-or-later — the reason Rewind itself must stay GPLv3 |
| `obs-ffmpeg-mux` helper | shipped alongside the binary, from the same libobs build | GPLv2-or-later |

## Game data

Riot's Data Dragon (champion/item art) is fetched at runtime, not bundled, and
is used under Riot's own terms for third-party applications. Rewind reads only
sanctioned local APIs — see `docs/COMPLIANCE.md`.
