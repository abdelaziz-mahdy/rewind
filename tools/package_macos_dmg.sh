#!/usr/bin/env bash
# Package a built Rewind.app into a drag-to-Applications .dmg.
#
# Usage: tools/package_macos_dmg.sh [<path-to-.app>] [<output.dmg>]
#   Defaults: build/macos/Build/Products/Release/rewind.app  ->  dist/Rewind.dmg
#
# No signing/notarization here (that's a v1.0 item) — this produces an
# unsigned local artifact that opens with a right-click → Open on first run.
# Pure hdiutil, no third-party tools, so it runs on a bare CI runner.
set -euo pipefail

APP="${1:-build/macos/Build/Products/Release/rewind.app}"
OUT="${2:-dist/Rewind.dmg}"

if [[ ! -d "$APP" ]]; then
  echo "error: app not found: $APP" >&2
  echo "build it first: FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES flutter build macos --release" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# The DMG contents: the app plus an /Applications symlink so users can drag
# it across.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

VOLNAME="Rewind"
echo "building $OUT from $APP ..."
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$OUT" >/dev/null

echo "done: $OUT ($(du -h "$OUT" | cut -f1))"
