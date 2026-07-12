import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/clip/clips_dir.dart';

void main() {
  test('macOS → ~/Movies/Rewind', () {
    expect(clipsDirPath(os: 'macos', env: {'HOME': '/Users/zee'}),
        p.join('/Users/zee', 'Movies', 'Rewind'));
  });
  test('Windows → %USERPROFILE%\\Videos\\Rewind', () {
    expect(clipsDirPath(os: 'windows', env: {'USERPROFILE': r'C:\Users\zee'}),
        p.joinAll([r'C:\Users\zee', 'Videos', 'Rewind']));
  });
  test('other OS falls back to ~/Rewind', () {
    expect(clipsDirPath(os: 'linux', env: {'HOME': '/home/zee'}),
        p.join('/home/zee', 'Rewind'));
  });
}
