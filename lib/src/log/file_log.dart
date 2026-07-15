import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart';

/// How many session log files to keep; older ones are pruned at startup.
const _keepLogFiles = 10;

/// Mirrors every talker entry into a per-session log file under
/// `<supportDir>/logs/`, so crashes and post-mortem debugging don't depend
/// on talker's in-memory history (gone with the process) or on the user
/// exporting from the Logs screen in time. Each line is written
/// synchronously with flush — this app logs a few lines a minute, and a
/// crash-proof trail is worth more than buffered writes.
///
/// Returns the active log file (also announced via a log line, so the Logs
/// screen tells the user where to find it).
File startFileLogging(Directory supportDir) {
  final dir = Directory(p.join(supportDir.path, 'logs'))
    ..createSync(recursive: true);

  // Prune old sessions. ISO-timestamp names sort lexically = by age.
  final existing = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.log'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  for (final old in existing.skip(_keepLogFiles - 1)) {
    try {
      old.deleteSync();
    } catch (_) {}
  }

  final stamp =
      DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  final file = File(p.join(dir.path, 'rewind-$stamp.log'));

  talker.stream.listen((entry) {
    try {
      file.writeAsStringSync(
        '${entry.generateTextMessage()}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Never let logging take the app down.
    }
  });

  talker.info('Logging to ${file.path}');
  return file;
}
