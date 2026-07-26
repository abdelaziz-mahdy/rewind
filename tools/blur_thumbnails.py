#!/usr/bin/env python3
"""Blur every cached video thumbnail in a clip library.

Rewind's product screenshots render against a REAL clip library
(`integration_test/readme_shots_test.dart`), which is what makes them worth
looking at — synthetic fixtures render grey placeholder tiles. But real
gameplay frames carry names: League draws a summoner nameplate above every
champion, and the kill feed and chat carry more. Those must not ship in a
public README.

Blurring is the only reliable fix. Picking "clean" frames is not repeatable
(a nameplate can appear anywhere in any frame), and relying on the text being
too small to read is not a standard — anyone can upscale.

This blurs the THUMBNAILS THEMSELVES, before the app loads them, so the UI
Rewind draws on top of each thumbnail — the K/D/A badge, the champion
monogram, the clip-count pill, the play triangle — still renders perfectly
sharp. Blurring the finished screenshot instead cannot tell those apart from
the video underneath, and smears them too.

Usage:
    python3 tools/blur_thumbnails.py <library-dir> [radius]
"""

import sys
from pathlib import Path
from PIL import Image, ImageFilter

# Enough to destroy ~10px nameplate text at thumbnail resolution while the
# frame still reads as gameplay: colours, silhouettes, the minimap.
DEFAULT_RADIUS = 6


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    lib = Path(sys.argv[1])
    radius = float(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_RADIUS
    thumbs = lib / ".thumbs"
    if not thumbs.is_dir():
        print(f"no .thumbs directory under {lib}", file=sys.stderr)
        return 1

    count = 0
    for p in sorted(thumbs.iterdir()):
        if p.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
            continue
        im = Image.open(p).convert("RGB").filter(ImageFilter.GaussianBlur(radius))
        im.save(p, quality=90)
        count += 1
    print(f"blurred {count} thumbnails in {thumbs} (radius {radius})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
