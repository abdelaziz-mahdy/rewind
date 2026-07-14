import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/clip/clips_dir.dart';

void main() {
  test('macOS → ~/Movies/Rewind', () {
    expect(clipsDirPath(os: 'macos', env: {'HOME': '/Users/zee'}),
        p.join('/Users/zee', 'Movies', 'Rewind'));
  });
  test('Windows → %USERPROFILE%\\Videos\\Rewind', () {
    // p.split normalizes separators on both hosts, so this pins the base,
    // segments, and order without reusing the implementation's join call.
    expect(
        p.split(
            clipsDirPath(os: 'windows', env: {'USERPROFILE': r'C:\Users\zee'})),
        [r'C:\Users\zee', 'Videos', 'Rewind']);
  });
  test('other OS falls back to ~/Rewind', () {
    expect(clipsDirPath(os: 'linux', env: {'HOME': '/home/zee'}),
        p.join('/home/zee', 'Rewind'));
  });

  group('resolveClipsDirPath', () {
    test('a non-blank override wins verbatim', () {
      expect(resolveClipsDirPath('/Volumes/gaming/Clips'),
          '/Volumes/gaming/Clips');
    });

    test('null and blank fall back to the per-OS default', () {
      final def =
          clipsDirPath(os: Platform.operatingSystem, env: Platform.environment);
      expect(resolveClipsDirPath(null), def);
      expect(resolveClipsDirPath('   '), def);
    });
  });
}
