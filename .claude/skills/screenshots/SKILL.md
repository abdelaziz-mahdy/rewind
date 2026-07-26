---
name: screenshots
description: Capture real screenshots of Rewind's UI — for design review, before/after comparison of a redesign, or to see what a screen actually looks like. Use whenever a task needs a picture of the app rather than a description. Explains why `screencapture` cannot work here.
---

# Screenshotting Rewind

## The one thing to know first

**Default to the integration-test path, which sidesteps TCC entirely:** it
renders the widget tree into a `RepaintBoundary` and calls `toImage()`. Pure
Dart on the real GPU, inside the app's own process — the OS screenshot API is
never involved, so no permission applies. Deterministic, and the only option
that works for before/after comparison or in CI.

(macOS's `integration_test` plugin also doesn't implement the
`captureScreenshot` channel, which is why `binding.takeScreenshot()` isn't the
answer either. `toImage` is.)

**`screencapture` fails from this shell** with `could not create image from
display` — but because Screen Recording isn't *granted*, NOT because it's
impossible. Verified 2026-07-26; the grant would go to **Terminal.app**
(`Terminal → login → zsh → claude`), not to Claude Code. `TCC.db` can't be
read to check (SIP), so probe it: `screencapture -x /tmp/probe.png`.

Ask for that grant only when the thing you need is **outside the Flutter
tree**, because the test path genuinely cannot reach it:

- the menu-bar `● REC` title (`TrayService.setTitle`) and the tray menu —
  still unverified on this branch for exactly this reason
- the native title bar and its drag region (open audit finding F-14)
- the real macOS Screen Recording permission dialog

Cost to state up front: macOS won't apply the grant to a running app, so
Terminal must be quit and reopened — **which ends the Claude Code session.**
Worth doing once, deliberately, not mid-task.

Cheaper alternative for this app specifically: Rewind itself already holds
Screen Recording permission (that is its whole job, and the grant survives
rebuilds via the signing identity — see CLAUDE.md). A debug-only trigger
beside `.save-now` / `.record-toggle` could capture the screen through
Rewind's own granted process — no terminal grant, no session restart.

## Existing tours

| File | What it shoots | Output |
|---|---|---|
| `integration_test/ui_tour_test.dart` | Individual screens (settings, match, player+trim with real FFmpeg, onboarding, supported games) | `screenshots/` |
| `integration_test/redesign_tour_test.dart` | The whole **shell** in five states (All Clips, game hub, Settings, first run, capture error) | `screenshots/<SHOT_DIR>/` |

Run one:

```bash
flutter test integration_test/redesign_tour_test.dart -d macos --dart-define=SHOT_DIR=after
```

Then read the PNGs back with the Read tool — **actually look at them.** A tour
that "passed" tells you nothing; the images are the artifact, and they are
where you'll spot the layout bug nobody catalogued.

## The pattern, if you need a new tour

```dart
final boundaryKey = GlobalKey();

Future<void> shoot(String name) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('screenshots/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
}

// Pin the canvas in setUp — see the sizing rule below.
const size = Size(1440, 900);
final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
view.physicalSize = size * 2;
view.devicePixelRatio = 2;

Widget frame(Widget child) => RepaintBoundary(
      key: boundaryKey,
      child: SizedBox.fromSize(
        size: size,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: rewindTheme(),
          home: child,
        ),
      ),
    );
```

Rules that made the difference:

- **`IntegrationTestWidgetsFlutterBinding.ensureInitialized()`**, not the
  widget-test binding. `MediaKit.ensureInitialized()` too if a `PlayerScreen`
  is in the tour.
- **Pin `view.physicalSize`, not just a `SizedBox`.** `pumpWidget` applies
  TIGHT constraints from the test surface, so a `SizedBox` in the tree is
  silently ignored — the first run of `redesign_tour_test.dart` captured
  1600x1200 and a later one 3024x1636 purely because the window differed.
  Reset it in `tearDown`. (An earlier version of this skill recommended the
  `SizedBox` alone; that was wrong.)
- **Shoot the width sweep too.** `redesign_tour_test.dart` runs 820 / 1280 /
  2200 — that sweep is what caught the fixed rail width and the missing
  shared content column. Grep the run log for `overflowed`; Flutter reports
  overflow banners even when the tour passes.
- **Seed real content.** A screenshot of an empty app proves nothing about a
  design. `redesign_tour_test.dart`'s `seeded()` builds two League matches
  with K/D/A, a result and a champion, plus a desktop session — copy it.
- **Set the live state you're documenting**: `coordinator.activeGameIds`,
  `activeGame`, `bufferActive`, `captureError`. The states are the design.
- Fakes, not real IO: `FakeCaptureEngine`, `FakeThumbnailGenerator` (see
  `test/fakes/`). `FfmpegKit` works on-device if you genuinely need a real
  video (the player trim tour does this) — it is slow, so don't unless asked.
- Bounded `pump(Duration(...))` before each `shoot`, never `pumpAndSettle` —
  the deck's ticker and any poll can keep a frame pending forever.

## `toImage()` limits

- It **deadlocks in a plain `testWidgets` test** once the tree is non-trivial
  (a `Shell` hangs every time). Symptom: the test never completes and the
  runner dies with `Bad state: Cannot close sink while adding stream`.
- **Two `toImage()` calls in one widget-test FILE can hang the second**, even
  with one call per test.
- So: do all pixel work in `integration_test/`, on the device. That path is
  reliable and can `shoot()` many times per test.

## Proving an invisible change

When the change is subtle — a focus ring, a hover state, a 1px border —
eyeballing two PNGs is not evidence. Diff them:

```python
from PIL import Image
import numpy as np
a = np.asarray(Image.open('before.png').convert('RGB'), dtype=int)
b = np.asarray(Image.open('after.png').convert('RGB'), dtype=int)
d = np.abs(a - b).sum(axis=2)
print('maxdiff', d.max(), 'pixels>100:', (d > 100).sum())
```

This is how the invisible focus ring was proven (2026-07-26): tabbing between
filter chips moved ~25 levels on one row of anti-aliased fringe and moved the
rail not one byte — the frames were byte-identical. After the fix, 627 vs 81.
**Identical bytes mean the state you thought you were capturing never
rendered** — check the interaction reached the widget before blaming styling.

## Output paths

`shoot()`'s path is relative to the PROJECT ROOT, not to anything you pass on
the command line. Passing an absolute path as `SHOT_DIR` writes
`screenshots/tmp/...` inside the repo. Pass a plain name.

## Before/after comparison across branches

This is the high-value case, and it has one trap: **a tour written against the
new API won't compile on the old branch**, so you get no "before".

The fix that worked (2026-07-25 broadcast-deck redesign): write the comparison
tour against **only the API surface that exists on both trees**. In practice
that means going through `Shell` and nothing else — its prop list is stable
across redesigns precisely so `main.dart` doesn't churn. No new widget
imports, no new optional parameters.

Then:

```bash
# after
flutter test integration_test/redesign_tour_test.dart -d macos --dart-define=SHOT_DIR=after

# before — check out the base branch IN PLACE and re-run.
# Keep the tour file UNTRACKED so it survives the checkout.
git checkout main
flutter test integration_test/redesign_tour_test.dart -d macos --dart-define=SHOT_DIR=before
git checkout -
```

**A `git worktree` does NOT work for this** (tried, 2026-07-25): a fresh
worktree fails at `Xcode failed to resolve Swift Package Manager dependencies`
because the macOS runner's package state isn't part of the checkout. Use the
in-place checkout.

`screenshots/` is git-ignored, so both output sets survive branch switches.

## Putting them in a document

For an HTML artifact, a strict CSP blocks every external request — images MUST
be inlined as `data:` URIs. Full-size PNGs are far too heavy; downscale and
re-encode first:

```bash
sips -Z 900 in.png --out tmp.png
sips -s format jpeg -s formatOptions 62 tmp.png --out out.jpg
```

That took a 10-image set from 1.7 MB to ~590 KB (~770 KB once base64'd),
which is fine for one page. `sips -s format webp` silently produces nothing on
this machine — don't rely on it.

Alternatively just send the PNGs with `SendUserFile`, which has no size
concern and renders them inline for the user.
