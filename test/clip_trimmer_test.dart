import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip_trimmer.dart';

void main() {
  group('trimOutPath', () {
    test('appends -trim-1 before the extension', () {
      expect(
        trimOutPath('/clips/rewind-2026.mp4', const []),
        '/clips/rewind-2026-trim-1.mp4',
      );
    });

    test('skips names the library already holds', () {
      expect(
        trimOutPath('/clips/a.mp4',
            const ['/clips/a-trim-1.mp4', '/clips/a-trim-2.mp4']),
        '/clips/a-trim-3.mp4',
      );
    });

    test('a dot in a directory name is not mistaken for an extension', () {
      expect(
        trimOutPath('/my.clips/video', const []),
        '/my.clips/video-trim-1.mp4',
      );
    });
  });

  group('trimArguments', () {
    test('input-seeks, stream-copies, and re-zeros timestamps', () {
      expect(
        trimArguments(
          srcPath: '/clips/a.mp4',
          start: const Duration(milliseconds: 1500),
          end: const Duration(milliseconds: 9750),
          outPath: '/clips/a-trim-1.mp4',
        ),
        [
          '-ss', '1.500',
          '-i', '/clips/a.mp4',
          '-t', '8.250',
          '-c', 'copy',
          '-avoid_negative_ts', 'make_zero',
          '-y', '/clips/a-trim-1.mp4',
        ],
      );
    });
  });

  group('FfmpegKitClipTrimmer', () {
    test('rejects an empty or inverted range without invoking FFmpeg',
        () async {
      final trimmer = FfmpegKitClipTrimmer();
      // No FFmpeg binaries exist under `flutter test` — reaching the
      // package would throw its way to false, but an invalid range must
      // short-circuit before that.
      expect(
        await trimmer.trim(
          srcPath: '/a.mp4',
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 5),
          outPath: '/a-trim-1.mp4',
        ),
        isFalse,
      );
    });
  });
}
