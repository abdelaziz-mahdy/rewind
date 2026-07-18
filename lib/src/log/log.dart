import 'dart:io';

import 'package:talker_flutter/talker_flutter.dart';

/// Mirrors every talker entry to a per-session log file, SYNCHRONOUSLY.
///
/// A [TalkerObserver], not a `talker.stream.listen(...)` subscription, on
/// purpose: stream listeners are delivered asynchronously (as microtasks),
/// so a crash right after a `talker.error(...)` could kill the process
/// before the listener ever ran — losing exactly the line a post-mortem
/// needs. Observer callbacks run inside the log call itself, so the line is
/// on disk (written with flush) before execution continues.
///
/// [file] is null until `startFileLogging` assigns it (the support dir is
/// only known asynchronously at startup); entries before that go to
/// talker's in-memory history only.
class FileLogObserver extends TalkerObserver {
  File? file;

  void _write(TalkerData entry) {
    final f = file;
    if (f == null) return;
    try {
      f.writeAsStringSync(
        '${entry.generateTextMessage()}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Never let logging take the app down.
    }
  }

  @override
  void onLog(TalkerData log) => _write(log);

  @override
  void onError(TalkerError err) => _write(err);

  @override
  void onException(TalkerException err) => _write(err);
}

/// The observer instance `startFileLogging` binds to a session file.
final FileLogObserver fileLogObserver = FileLogObserver();

/// App-wide logger. One instance, imported wherever something needs to be
/// recorded — `talker.info(...)`, `talker.warning(...)`, `talker.error(...)`,
/// `talker.handle(err, stack)`. The rail's "Logs" item opens a [TalkerScreen]
/// over this same instance so users can see what happened without digging
/// through console output.
final Talker talker = TalkerFlutter.init(observer: fileLogObserver);
