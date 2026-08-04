import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/log/file_log.dart';

void main() {
  late Directory dir;
  final now = DateTime(2026, 8, 2, 12);

  setUp(() => dir = Directory.systemTemp.createTempSync('rewind_logs'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  File write(String name, {required int daysOld, int bytes = 100}) {
    final f = File(p.join(dir.path, name))
      ..writeAsBytesSync(List.filled(bytes, 0));
    f.setLastModifiedSync(now.subtract(Duration(days: daysOld)));
    return f;
  }

  test('deletes both session logs and perf samples past the cutoff', () {
    final oldLog = write('rewind-2026-07-01T10-00-00.log', daysOld: 30);
    final oldPerf =
        write('perf-2026-07-01T10-00-00.jsonl', daysOld: 30, bytes: 500);
    final freshLog = write('rewind-2026-08-01T10-00-00.log', daysOld: 1);
    final freshPerf = write('perf-2026-08-01T10-00-00.jsonl', daysOld: 1);

    final result = pruneLogs(dir, keepDays: 14, now: now);

    expect(oldLog.existsSync(), isFalse);
    expect(oldPerf.existsSync(), isFalse);
    expect(freshLog.existsSync(), isTrue);
    expect(freshPerf.existsSync(), isTrue);
    expect(result.files, 2);
    expect(result.bytes, 600);
  });

  test('null keepDays keeps everything', () {
    final ancient = write('perf-2020-01-01T00-00-00.jsonl', daysOld: 2000);
    expect(pruneLogs(dir, keepDays: null, now: now).files, 0);
    expect(ancient.existsSync(), isTrue);
  });

  // The file being written to is the one most likely to matter, and a
  // long-running session's log can itself be older than the cutoff.
  test('never deletes the active session log, however old it looks', () {
    final active = write('rewind-2026-06-01T10-00-00.log', daysOld: 60);
    activeLogFile = active;
    addTearDown(() => activeLogFile = null);

    final result = pruneLogs(dir, keepDays: 7, now: now);

    expect(active.existsSync(), isTrue);
    expect(result.files, 0);
  });

  test('leaves files it does not own alone', () {
    final other = write('settings.json', daysOld: 900);
    final thumb = write('something.jpg', daysOld: 900);

    pruneLogs(dir, keepDays: 1, now: now);

    expect(other.existsSync(), isTrue);
    expect(thumb.existsSync(), isTrue);
  });

  test('logsUsage counts only what pruneLogs manages', () {
    write('rewind-a.log', daysOld: 1, bytes: 10);
    write('perf-a.jsonl', daysOld: 1, bytes: 20);
    write('unrelated.txt', daysOld: 1, bytes: 1000);

    final usage = logsUsage(dir);

    expect(usage.files, 2);
    expect(usage.bytes, 30);
  });

  test('a missing logs directory is not an error', () {
    final gone = Directory(p.join(dir.path, 'nope'));
    expect(pruneLogs(gone, keepDays: 7, now: now).files, 0);
    expect(logsUsage(gone).files, 0);
  });
}
