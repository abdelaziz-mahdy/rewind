import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/app_version.dart';

void main() {
  test('kAppVersion matches pubspec.yaml', () {
    // The About page shows kAppVersion. If a release bumps pubspec and
    // forgets this constant, the app would confidently report the wrong
    // version to the user AND to every bug report they file.
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    final version = line.split(':')[1].trim().split('+').first;
    expect(kAppVersion, version,
        reason: 'Bump kAppVersion in lib/src/app_version.dart to match '
            'pubspec.yaml (currently $version).');
  });
}
