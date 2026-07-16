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
    // Compare join-to-join like the macOS/linux cases: both sides use the
    // host's path context, so this holds on a POSIX host AND a real Windows
    // runner. (An earlier p.split-based assertion passed only on POSIX, where
    // '\' isn't a separator — on Windows p.split decomposes 'C:\Users\zee'.)
    expect(clipsDirPath(os: 'windows', env: {'USERPROFILE': r'C:\Users\zee'}),
        p.join(r'C:\Users\zee', 'Videos', 'Rewind'));
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
