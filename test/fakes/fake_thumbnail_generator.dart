import 'dart:async';
import 'dart:io';

import 'package:rewind/src/clip/thumbnail_generator.dart';

/// A [ThumbnailGenerator] that writes a tiny placeholder file instead of
/// touching media_kit — the seam every test in this suite exercises instead
/// of `MediaKitThumbnailGenerator` (never constructible in a widget-test
/// host process; see CLAUDE.md's testing gotchas).
class FakeThumbnailGenerator implements ThumbnailGenerator {
  /// Paths (by [videoPath]) that should report failure instead of writing a
  /// file — simulates a corrupt/unsupported video.
  final Set<String> failFor;

  /// Delay before completing, to let tests observe an in-flight generation
  /// (e.g. asserting single-flight de-duplication).
  final Duration delay;

  int callCount = 0;
  final List<String> generatedFor = [];

  FakeThumbnailGenerator({this.failFor = const {}, this.delay = Duration.zero});

  @override
  Future<bool> generate(String videoPath, String thumbPath) async {
    callCount++;
    // `delay` (when used) is a real Timer — fine in plain `test()` bodies
    // (this suite's cache tests), but never used by the ClipTile widget
    // tests, which need everything below to stay synchronous. Real async
    // `dart:io` (writeAsBytes/create) schedules completion on the real OS
    // event loop, which never fires inside a `testWidgets` body's
    // fake-async zone (CLAUDE.md's testing gotchas) — the *Sync variants
    // below block the call stack instead, so they complete within the same
    // synchronous turn no matter which zone runs them.
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failFor.contains(videoPath)) return false;
    generatedFor.add(videoPath);
    final file = File(thumbPath);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const [0xFF, 0xD8, 0xFF]); // JPEG-ish magic bytes
    return true;
  }
}
