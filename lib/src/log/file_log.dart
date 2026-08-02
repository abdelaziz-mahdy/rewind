import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart';

/// Hard cap on session log files, applied at startup BEFORE settings are
/// loaded (see [startFileLogging]) — the user's own retention policy needs
/// settings, which are read a few lines later in `main`. Deliberately
/// generous: this is a runaway-growth backstop, not the policy.
const _keepLogFiles = 50;

/// What one [pruneLogs] sweep removed, so a caller can report it rather than
/// deleting silently.
typedef LogPruneResult = ({int files, int bytes});

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

/// Deletes diagnostic logs older than [keepDays] — BOTH session logs
/// (`rewind-*.log`) and the perf samples written beside them
/// (`perf-*.jsonl`), which are the bulk of the bytes: perf sampling writes
/// roughly 150 KB per session hour, so on a busy machine it outweighs the
/// session logs by an order of magnitude.
///
/// One owner for both kinds, driven by [AppSettings.logRetentionDays]. They
/// used to age out under two unrelated hardcoded rules — the last 10 session
/// files, and 14 days of perf samples — so "how long does Rewind keep logs?"
/// had two different answers and neither was the user's to set.
///
/// [keepDays] null keeps everything. The ACTIVE session's file is never
/// deleted, whatever its age says: a long-running session's log is the one
/// most likely to matter, and deleting the file being written to would lose
/// the very evidence a user is usually here to collect.
LogPruneResult pruneLogs(
  Directory logsDir, {
  required int? keepDays,
  DateTime? now,
}) {
  if (keepDays == null || keepDays <= 0) return (files: 0, bytes: 0);
  final cutoff = (now ?? DateTime.now()).subtract(Duration(days: keepDays));
  final active = activeLogFile?.path;

  List<FileSystemEntity> existing;
  try {
    existing = logsDir.listSync();
  } on FileSystemException {
    return (files: 0, bytes: 0);
  }

  var files = 0, bytes = 0;
  for (final entry in existing) {
    if (entry is! File) continue;
    final name = p.basename(entry.path);
    final isLog = name.startsWith('rewind-') && name.endsWith('.log');
    final isPerf = name.startsWith('perf-') && name.endsWith('.jsonl');
    if (!isLog && !isPerf) continue;
    if (entry.path == active) continue;
    try {
      final stat = entry.statSync();
      if (!stat.modified.isBefore(cutoff)) continue;
      entry.deleteSync();
      files++;
      bytes += stat.size;
    } on FileSystemException {
      // A locked or already-removed file must not stop the sweep.
    }
  }
  return (files: files, bytes: bytes);
}

/// Total size of everything [pruneLogs] manages, for the Settings readout.
LogPruneResult logsUsage(Directory logsDir) {
  List<FileSystemEntity> existing;
  try {
    existing = logsDir.listSync();
  } on FileSystemException {
    return (files: 0, bytes: 0);
  }
  var files = 0, bytes = 0;
  for (final entry in existing) {
    if (entry is! File) continue;
    final name = p.basename(entry.path);
    if (!(name.startsWith('rewind-') && name.endsWith('.log')) &&
        !(name.startsWith('perf-') && name.endsWith('.jsonl'))) {
      continue;
    }
    try {
      bytes += entry.statSync().size;
      files++;
    } on FileSystemException {
      // Counted as absent; a readout is not worth failing over.
    }
  }
  return (files: files, bytes: bytes);
}
