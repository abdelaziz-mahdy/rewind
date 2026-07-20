import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rewind/src/clip/thumbnail_generator.dart';

/// A real, decodable 1x1 JPEG. The fake used to write three bare magic
/// bytes (`FF D8 FF`), which is NOT a valid image: `Image.file` throws
/// "Invalid image data", and although `ClipTile`'s errorBuilder catches it
/// visually, Flutter still records the codec exception globally — which
/// trips `takeException()` and flakes any test (and the integration-test UI
/// tour) that renders a tile. A valid image decodes cleanly.
final Uint8List _tinyJpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
  'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
  'AAAAAAAAAAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAT8AH//Z',
);

/// A [ThumbnailGenerator] that writes a tiny placeholder file instead of
/// touching media_kit — the seam every test in this suite exercises instead
/// of `FfmpegThumbnailGenerator` (FFmpeg binaries absent in the widget-test
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
    file.writeAsBytesSync(_tinyJpeg); // a real, decodable 1x1 JPEG
    return true;
  }
}
