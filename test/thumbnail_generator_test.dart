import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/thumbnail_generator.dart';

void main() {
  test('thumbnailArguments seeks past the leader and writes one scaled frame',
      () {
    expect(
      thumbnailArguments('/clips/a.mp4', '/clips/.thumbs/a.jpg'),
      [
        '-ss', '1',
        '-i', '/clips/a.mp4',
        '-frames:v', '1',
        '-vf', 'scale=640:-2',
        '-q:v', '3',
        '-y', '/clips/.thumbs/a.jpg',
      ],
    );
  });
}
