#!/usr/bin/env bash
#
# Regenerate the product screenshots used by README.md and the hosted page.
#
#   tools/readme_shots.sh [library-dir]
#
# Defaults to ~/Movies/Rewind. The library must have clips in it — real
# gameplay thumbnails are the whole point, and the tour skips rather than
# shipping an empty grid.
#
# What this does, and why each step exists:
#
#  1. Copies the library into a scratch dir and BLURS its thumbnails. Real
#     gameplay frames carry summoner names (nameplates, kill feed, chat) and
#     those must not ship publicly. Blurring the thumbnails before the app
#     loads them keeps the UI Rewind draws on top — K/D/A, the count pill,
#     the play triangle — perfectly sharp; blurring the finished screenshot
#     smears those too. The originals are never touched.
#  2. Runs the render tour, which draws the real UI at a pinned 1280x800 @2x.
#     NOT `screencapture`: that photographs the whole desktop (wallpaper,
#     dock, whatever window is behind), can only be taken when nobody is
#     using the machine, and can't be re-run after a UI change.
#  3. Resizes to 1600px and palette-quantizes — ~1.5 MB down to ~350 KB with
#     no visible banding, which matters for a page people open on mobile.
#
set -euo pipefail

LIB="${1:-$HOME/Movies/Rewind}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -f "$LIB/clips.json" ]; then
  echo "no clips.json under $LIB — point this at a real clip library" >&2
  exit 1
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
SAFE="$SCRATCH/library"
mkdir -p "$SAFE/.thumbs"

echo "==> staging a redacted copy of $LIB"
# Videos are symlinked (they can be gigabytes and are only opened for
# thumbnail generation); the index is rewritten to point at them, so the app
# resolves .thumbs inside the scratch copy rather than the real library.
for f in "$LIB"/*.mp4; do
  [ -e "$f" ] || continue
  ln -s "$f" "$SAFE/$(basename "$f")"
done
for j in clips.json matches.json; do
  [ -f "$LIB/$j" ] && python3 - "$LIB/$j" "$SAFE/$j" "$LIB" "$SAFE" <<'PY'
import json, sys
src, dst, old, new = sys.argv[1:5]
raw = open(src).read().replace(old.rstrip('/'), new.rstrip('/'))
json.loads(raw)  # fail loudly rather than writing a corrupt index
open(dst, 'w').write(raw)
PY
done
cp "$LIB"/.thumbs/*.jpg "$SAFE/.thumbs/" 2>/dev/null || true

python3 tools/blur_thumbnails.py "$SAFE"

echo "==> rendering"
flutter test integration_test/readme_shots_test.dart -d macos \
  --dart-define=LIB_DIR="$SAFE" \
  --dart-define=SHOT_DIR=readme

echo "==> installing into docs/images"
install_shot() { # <source-name> <dest-name>
  sips --resampleWidth 1600 "screenshots/readme/$1.png" \
    --out "docs/images/$2.png" >/dev/null
  python3 - "docs/images/$2.png" <<'PY'
import sys
from PIL import Image
p = sys.argv[1]
Image.open(p).convert("RGB").quantize(colors=256).save(p, optimize=True)
PY
  echo "    docs/images/$2.png  ($(du -h "docs/images/$2.png" | cut -f1))"
}

install_shot 01-all-clips screenshot
install_shot 02-game-hub  matches
install_shot 04-settings  settings
install_shot 03-recorder  recorder

echo "==> done. Review the images before committing."
