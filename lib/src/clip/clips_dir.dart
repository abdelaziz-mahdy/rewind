import 'dart:io';
import 'package:path/path.dart' as p;

/// Where clips live per OS. Pure so it is testable; [ensureClipsDir] applies
/// it to the real environment.
String clipsDirPath({required String os, required Map<String, String> env}) {
  switch (os) {
    case 'macos':
      return p.join(env['HOME'] ?? '.', 'Movies', 'Rewind');
    case 'windows':
      return p.joinAll([env['USERPROFILE'] ?? '.', 'Videos', 'Rewind']);
    default:
      return p.join(env['HOME'] ?? '.', 'Rewind');
  }
}

Future<Directory> ensureClipsDir() async => Directory(clipsDirPath(
      os: Platform.operatingSystem,
      env: Platform.environment,
    )).create(recursive: true);
