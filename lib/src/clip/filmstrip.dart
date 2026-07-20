import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../log/log.dart';

/// How many frames a player filmstrip samples across a clip. Enough that
/// every RangeSlider handle position sits near a visible frame, few enough
/// that generation stays sub-second for typical clips.
const int kFilmstripFrameCount = 12;

/// The FFmpeg argument list for a filmstrip: [frameCount] frames sampled
/// evenly across [durationSeconds] of the source, scaled to 160 px wide
/// (aspect preserved, even height), written as `frame_%02d.jpg` under
/// [outDir]. One FFmpeg session for the whole strip — not one per frame.
/// Pure so tests pin the exact command.
List<String> filmstripArguments({
  required String videoPath,
  required double durationSeconds,
  required String outDir,
  int frameCount = kFilmstripFrameCount,
}) {
  // fps = frames-wanted / clip-duration samples evenly across the whole
  // clip. Guard degenerate durations so the filter never divides by zero.
  final fps = frameCount / (durationSeconds <= 0 ? 1 : durationSeconds);
  return [
    '-i', videoPath,
    '-vf', 'fps=${fps.toStringAsFixed(6)},scale=160:-2',
    '-frames:v', '$frameCount',
    '-q:v', '5',
    '-y', '$outDir/frame_%02d.jpg',
  ];
}

/// The per-clip cache directory for filmstrip frames, under the system temp
/// dir — regenerable throwaway data that must not pollute the clips
/// library. Keyed by the source file name + its mtime, so an overwritten
/// clip file never shows a stale strip.
String filmstripCacheDir(String videoPath, DateTime modified, String tmpRoot) {
  final base = videoPath.split('/').last.replaceAll('.', '_');
  return '$tmpRoot/rewind-filmstrip/$base-${modified.millisecondsSinceEpoch}';
}

/// Generates (and caches) the trim-mode filmstrip for a clip. Seam so tests
/// fake it — the real one needs the bundled FFmpeg binaries, absent in the
/// test host process.
abstract class FilmstripGenerator {
  /// Returns the ordered frame image paths for the clip at [videoPath]
  /// (whose duration the caller already knows from the player), or an empty
  /// list when generation fails — the trim bar then just shows its plain
  /// track; a missing filmstrip must never block trimming itself.
  Future<List<String>> generate(String videoPath, Duration duration);
}

/// FFmpeg-backed [FilmstripGenerator] (`ffmpeg_kit_flutter_new`, same
/// package as trimming/thumbnails). Cached per clip file + mtime under the
/// system temp dir; a warm cache returns without launching FFmpeg at all.
class FfmpegFilmstripGenerator implements FilmstripGenerator {
  @override
  Future<List<String>> generate(String videoPath, Duration duration) async {
    try {
      final src = File(videoPath);
      if (!await src.exists()) return const [];
      final modified = await src.lastModified();
      final dir = Directory(filmstripCacheDir(
          videoPath, modified, Directory.systemTemp.path));

      final expected = [
        for (var i = 1; i <= kFilmstripFrameCount; i++)
          '${dir.path}/frame_${i.toString().padLeft(2, '0')}.jpg',
      ];
      if (await _allExist(expected)) return expected;

      await dir.create(recursive: true);
      final session = await FFmpegKit.executeWithArguments(filmstripArguments(
        videoPath: videoPath,
        durationSeconds: duration.inMilliseconds / 1000,
        outDir: dir.path,
      ));
      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        talker.warning('Filmstrip: ffmpeg failed for $videoPath');
        return const [];
      }
      // Very short clips can legitimately yield fewer frames than asked —
      // return whatever landed, in order.
      final produced = <String>[];
      for (final path in expected) {
        if (await File(path).exists()) produced.add(path);
      }
      return produced;
    } catch (err, stack) {
      talker.handle(err, stack);
      return const [];
    }
  }

  Future<bool> _allExist(List<String> paths) async {
    for (final p in paths) {
      if (!await File(p).exists()) return false;
    }
    return true;
  }
}
