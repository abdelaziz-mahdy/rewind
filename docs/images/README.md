# README images

Real in-app screenshots used by the top-level `README.md` (captured on macOS,
debug banner hidden, resized to 1600px wide):

- `screenshot.png` — hero: the **All Clips** library, grouped by game.
- `matches.png` — a game hub with clips grouped into **match cards** (K/D,
  champion, mode).
- `settings.png` — **Capture** settings (buffer, display/app target,
  follow-the-game, mic).

To refresh a shot on macOS:

1. Open Rewind and get it to the screen you want.
2. Press **⌘⇧4**, then **Space**, then click the Rewind window.
3. Resize + overwrite, e.g.:
   ```bash
   sips --resampleWidth 1600 ~/Desktop/shot.png --out docs/images/screenshot.png
   ```

(The debug banner is already hidden via `debugShowCheckedModeBanner: false`,
so window shots come out clean.)
