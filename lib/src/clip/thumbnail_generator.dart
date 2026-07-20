import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../log/log.dart';

/// Seam for producing a thumbnail image on disk from a video file. Kept
/// abstract so tests never touch the real FFmpeg binaries (not present in
/// the test host process). Tests exercise a `FakeThumbnailGenerator`
/// against this interface instead.
abstract class ThumbnailGenerator {
  /// Writes a thumbnail image for the video at [videoPath] to [thumbPath].
  /// Returns whether it succeeded. Must never throw — a broken/unsupported
  /// video is a normal, expected outcome, not an app-crashing one.
  Future<bool> generate(String videoPath, String thumbPath);
}

/// The FFmpeg argument list for a thumbnail grab: seek 1 s in (past any
/// black leader frame — every Rewind clip is far longer than that; the
/// replay buffer is ≥15 s), decode one frame, scale to a 640-wide preview
/// (aspect preserved; -2 keeps the height even, which some JPEG paths
/// insist on). Pure so tests pin the exact command.
List<String> thumbnailArguments(String videoPath, String thumbPath) => [
      '-ss', '1',
      '-i', videoPath,
      '-frames:v', '1',
      '-vf', 'scale=640:-2',
      '-q:v', '3',
      '-y', thumbPath,
    ];

/// FFmpeg-backed [ThumbnailGenerator] (`ffmpeg_kit_flutter_new`) — replaced
/// the media_kit headless-Player approach, which needed a whole pile of
/// hard-won workarounds (an off-screen VideoController purely as a render
/// target, subscribe-before-open duration races, blind seeks when mpv
/// wouldn't report a duration, stale-frame sleeps — see CLAUDE.md's
/// media_kit gotchas for the archaeology). One decoded frame via ffmpeg has
/// none of those failure modes and needs no mpv at all.
class FfmpegThumbnailGenerator implements ThumbnailGenerator {
  @override
  Future<bool> generate(String videoPath, String thumbPath) async {
    try {
      await File(thumbPath).parent.create(recursive: true);
      final session = await FFmpegKit.executeWithArguments(
          thumbnailArguments(videoPath, thumbPath));
      final ok = ReturnCode.isSuccess(await session.getReturnCode());
      if (!ok) {
        talker.warning('Thumbnail: ffmpeg failed for $videoPath');
        return false;
      }
      // ffmpeg can exit 0 having written nothing for a sub-second/corrupt
      // file — verify the artifact exists before reporting success.
      final written = await File(thumbPath).exists();
      if (!written) {
        talker.warning('Thumbnail: ffmpeg wrote no file for $videoPath');
      }
      return written;
    } catch (err, stack) {
      talker.handle(err, stack);
      return false;
    }
  }
}
