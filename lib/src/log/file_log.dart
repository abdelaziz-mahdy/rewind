import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart';

/// How many session log files to keep; older ones are pruned at startup.
const _keepLogFiles = 10;

/// The log file the current session is writing to, or null before
/// [startFileLogging] runs. The Logs screen surfaces its path.
File? activeLogFile;

/// Mirrors every talker entry into a per-session log file under
/// `<supportDir>/logs/`, so crashes and post-mortem debugging don't depend
/// on talker's in-memory history (gone with the process) or on the user
/// exporting from the Logs screen in time. Binds [fileLogObserver] (already
/// attached to the talker at construction) to this session's file — an
/// observer writes SYNCHRONOUSLY inside the log call, unlike the previous
/// `talker.stream` subscription, whose microtask delivery could lose the
/// final pre-crash entries (see [FileLogObserver]'s doc).
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

  fileLogObserver.file = file;

  activeLogFile = file;
  talker.info('Logging to ${file.path}');
  return file;
}
