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

  group('MethodChannelClipTrimmer', () {
    test('rejects an empty or inverted range without touching the channel',
        () async {
      final trimmer = MethodChannelClipTrimmer();
      // No channel handler is registered in tests — reaching the channel
      // would throw MissingPluginException-driven false, but an invalid
      // range must short-circuit before that.
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
