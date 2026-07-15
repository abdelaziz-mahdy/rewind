import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../log/log.dart';

/// Seam for producing a thumbnail image on disk from a video file. Kept
/// abstract so tests never construct a real media_kit [Player] — per
/// CLAUDE.md's testing gotchas, media_kit needs native libmpv, which isn't
/// loaded in the widget-test host process. Tests exercise a
/// `FakeThumbnailGenerator` against this interface instead.
abstract class ThumbnailGenerator {
  /// Writes a thumbnail image for the video at [videoPath] to [thumbPath].
  /// Returns whether it succeeded. Must never throw — a broken/unsupported
  /// video is a normal, expected outcome, not an app-crashing one.
  Future<bool> generate(String videoPath, String thumbPath);
}

/// Headless media_kit-backed [ThumbnailGenerator]: opens the clip without
/// playing it, seeks a little into it (past any fade-in/black leader frame),
/// and grabs a frame via [Player.screenshot]. Nothing ever builds a `Video`
/// widget for this — playback is never shown — but a [VideoController] is
/// still required (see its comment below) purely so mpv has a render target
/// to grab a frame from.
class MediaKitThumbnailGenerator implements ThumbnailGenerator {
  /// Bounds how long to wait for the player to report a duration, and
  /// separately for the first frame to render, before giving up. A corrupt
  /// or unsupported file must not hang the sequential startup backfill queue.
  final Duration timeout;

  MediaKitThumbnailGenerator({this.timeout = const Duration(seconds: 8)});

  @override
  Future<bool> generate(String videoPath, String thumbPath) async {
    final player = Player();
    // mpv's `screenshot-raw` command reads from the video output's current
    // frame. With the default headless configuration (no VideoController
    // attached, `vo=null`), there IS no such frame and screenshot() always
    // returns null — confirmed empirically: duration/seek/screenshot all
    // completed in ~400ms with a null result until a VideoController was
    // added. It's never displayed; it just needs to exist.
    final controller = VideoController(player);
    try {
      // Subscribe to the duration stream BEFORE calling open(): mpv's
      // property observers are registered at Player() construction time,
      // so the "duration known" event can fire as early as during open()
      // itself. durationController is a broadcast StreamController — a
      // subscriber that starts listening only after open() completes can
      // miss that event entirely (broadcast streams never replay past
      // events), hanging until the timeout on every single call.
      //
      // The duration is now a HINT, not a gate: with an AAC audio track
      // present (added 2026-07-14), mpv frequently never emits a positive
      // duration on the headless stream even though the file is perfectly
      // valid (ffprobe/mdls read it fine) — which was silently killing
      // every clip's thumbnail. So we no longer fail when it's missing; we
      // just blind-seek to a fixed 1 s (every Rewind clip is far longer
      // than that — the replay buffer is ≥15 s and recordings are longer),
      // past any black leader frame.
      final durationFuture = player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3), onTimeout: () => Duration.zero);
      await player.open(Media(videoPath), play: false);

      final duration = await durationFuture;
      // Target a little past the start; when the duration is known and the
      // clip is very short, cap at 10% of it, else a fixed 1 s.
      final Duration target;
      if (duration > Duration.zero &&
          duration * 0.1 < const Duration(seconds: 1)) {
        target = duration * 0.1;
      } else {
        target = const Duration(seconds: 1);
      }
      await player.seek(target);
      // Wait for the VideoController's render target to actually produce a
      // frame at the seeked position before grabbing a screenshot of it.
      await controller.waitUntilFirstFrameRendered
          .timeout(timeout, onTimeout: () {});
      // Extra buffer past that signal — screenshot() has still been
      // observed to occasionally grab a stale pre-seek frame otherwise.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final bytes = await player
          .screenshot(format: 'image/jpeg')
          .timeout(timeout, onTimeout: () => null);
      if (bytes == null || bytes.isEmpty) {
        talker.warning('Thumbnail: empty screenshot for $videoPath');
        return false;
      }

      final file = File(thumbPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      return true;
    } catch (err, stack) {
      talker.handle(err, stack);
      return false;
    } finally {
      // Always dispose, success or failure — this is a throwaway headless
      // player, never surfaced to the UI. Unlike PlayerScreen's dispose
      // (synchronous State.dispose, so fire-and-forget there), generate()
      // is already async, so awaiting here just ensures the native player
      // is fully torn down before the next backfill iteration opens one.
      await player.dispose();
    }
  }
}
