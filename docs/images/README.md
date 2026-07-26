# README images

Product screenshots used by the top-level `README.md` and the hosted page:

- `screenshot.png` — hero: the **All Clips** library, grouped by game.
- `matches.png` — a game hub with clips grouped into **match cards** (K/D/A,
  champion, mode).
- `settings.png` — **Capture** settings (instant replay, video preset, audio).
- `recorder.png` — the recorder panel open over the library.

## Regenerating them

One command. Re-run it whenever the UI changes:

```bash
tools/readme_shots.sh                    # defaults to ~/Movies/Rewind
tools/readme_shots.sh /path/to/library   # or point it somewhere else
```

It stages a redacted copy of the library, renders the real UI through
`integration_test/readme_shots_test.dart` at a pinned 1280x800 @2x, then
resizes to 1600px and palette-quantizes into this directory (~1.5 MB down to
~200 KB each, no visible banding). Your real library is never modified.

Review the images before committing — that is the whole point of generating
them, and a passing tour proves nothing about how they look.

## Three decisions worth not re-litigating

**Real library, not fixtures.** The design-review tours
(`ui_tour_test.dart`, `redesign_tour_test.dart`) seed synthetic clips, which
render grey placeholder tiles — fine for judging layout, useless for showing
anyone what the app is. These shots load a real library so the grid shows real
gameplay.

**Thumbnails are blurred, and blurred BEFORE the app loads them.** Real
gameplay frames carry other people's names — League draws a summoner nameplate
above every champion, plus the kill feed and chat. Blurring the finished
screenshot cannot tell the video apart from the UI Rewind draws on top of it,
so the K/D/A badge, count pill and play triangle came out smeared too;
blurring the cached thumbnails first leaves all of that perfectly sharp. See
`tools/blur_thumbnails.py`.

**Not `screencapture`.** Tried it. It photographs the whole desktop —
wallpaper, dock, whatever window is behind Rewind — so every shot needs
cropping and leaks whatever the machine happened to be showing. It also can't
be taken while anyone is using the machine, and can't be re-run after a UI
change.

A debug `.screenshot` trigger inside the app was tried — Rewind holds Screen
Recording permission, so `screencapture` spawned from it worked where the same
command from a terminal fails. **It was removed.** Running a second
screen-capture client alongside the app's own ScreenCaptureKit session is a
hack, and on 2026-07-26 the replay buffer died six minutes after firing it and
silently dropped eight clips across three matches. Don't re-add it.

If you need a real screen capture — the menu bar, the tray menu, native window
chrome — grant **Terminal.app** (or whichever terminal hosts the shell) Screen
Recording under System Settings → Privacy & Security, quit and reopen it, and
run `screencapture` normally.

The previous instructions here were ⌘⇧4 + Space + click. That is exactly why
the old images sat stale for ten days across a full redesign.
