import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

import '../log/log.dart';

/// Reads a media file's duration. Seam so tests supply fixed durations
/// (the real one needs the bundled ffprobe, absent in the test host).
abstract class DurationProber {
  /// The clip's duration, or null when the file is missing/unreadable.
  /// Never throws.
  Future<Duration?> probe(String path);
}

/// ffprobe-backed [DurationProber] (`ffmpeg_kit_flutter_new`, same package
/// as trim/thumbnails/filmstrip/concat).
class FfprobeDurationProber implements DurationProber {
  /// Memoized per path — the match viewer probes every clip of a match on
  /// open, and re-opens shouldn't re-probe unchanged files. Path-keyed (no
  /// mtime): clip files are write-once (the mux writes, nothing edits them
  /// in place).
  final _cache = <String, Duration>{};

  @override
  Future<Duration?> probe(String path) async {
    final hit = _cache[path];
    if (hit != null) return hit;
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final seconds =
          double.tryParse(session.getMediaInformation()?.getDuration() ?? '');
      if (seconds == null || seconds <= 0) return null;
      final d = Duration(milliseconds: (seconds * 1000).round());
      _cache[path] = d;
      return d;
    } catch (err, stack) {
      talker.handle(err, stack);
      return null;
    }
  }
}
