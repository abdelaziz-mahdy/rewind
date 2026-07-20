import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/filmstrip.dart';

void main() {
  test('filmstripArguments samples evenly and writes numbered frames', () {
    expect(
      filmstripArguments(
        videoPath: '/clips/a.mp4',
        durationSeconds: 30,
        outDir: '/tmp/strip',
        frameCount: 12,
      ),
      [
        '-i', '/clips/a.mp4',
        '-vf', 'fps=0.400000,scale=160:-2',
        '-frames:v', '12',
        '-q:v', '5',
        '-y', '/tmp/strip/frame_%02d.jpg',
      ],
    );
  });

  test('filmstripArguments guards a zero duration', () {
    final args = filmstripArguments(
      videoPath: '/a.mp4',
      durationSeconds: 0,
      outDir: '/t',
      frameCount: 12,
    );
    expect(args[3], startsWith('fps=12.000000'));
  });

  test('filmstripCacheDir keys by file name and mtime', () {
    final dir = filmstripCacheDir(
        '/clips/a.mp4', DateTime.fromMillisecondsSinceEpoch(1234), '/tmp');
    expect(dir, '/tmp/rewind-filmstrip/a_mp4-1234');
  });
}
