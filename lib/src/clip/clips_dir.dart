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

/// The clips directory to use given an optional user [override] (the
/// Settings "Recordings folder" — `AppSettings.clipsDirPath`): the override
/// verbatim when set and non-blank, else the per-OS default.
String resolveClipsDirPath(String? override) =>
    (override != null && override.trim().isNotEmpty)
        ? override
        : clipsDirPath(
            os: Platform.operatingSystem,
            env: Platform.environment,
          );

Future<Directory> ensureClipsDir({String? override}) async =>
    Directory(resolveClipsDirPath(override)).create(recursive: true);
