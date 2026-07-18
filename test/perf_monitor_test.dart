import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/log/log.dart';
import 'package:rewind/src/log/perf_monitor.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'fakes/fake_capture_engine.dart';

/// Builds the JSON `rewind_perf_stats_json` would return, so tests drive
/// [PerfMonitor] without touching the real FFI/native shim.
String _statsJson({
  double cpuUserS = 0,
  double cpuSysS = 0,
  int rssBytes = 0,
  int obsTotal = 0,
  int obsLagged = 0,
  int voTotal = 0,
  int voSkipped = 0,
}) =>
    jsonEncode({
      'cpu_user_s': cpuUserS,
      'cpu_sys_s': cpuSysS,
      'rss_bytes': rssBytes,
      'obs_total_frames': obsTotal,
      'obs_lagged_frames': obsLagged,
      'vo_total_frames': voTotal,
      'vo_skipped_frames': voSkipped,
    });

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_perf_monitor');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('writes valid JSONL lines with cpu%/deltas computed across two samples',
      () {
    final engine = FakeCaptureEngine();
    engine.perfStatsJsonValue = _statsJson(
      cpuUserS: 1.0,
      rssBytes: 100 * 1024 * 1024,
      obsTotal: 100,
      voTotal: 100,
    );
    final monitor = PerfMonitor(
      engine: engine,
      activeGameGetter: () => 'league_of_legends',
      logsDir: tmp,
      interval: const Duration(seconds: 10),
      now: () => DateTime(2026, 1, 1),
    );
    monitor.start();
    monitor.sampleOnce(); // baseline: no previous sample, deltas must be 0

    engine.perfStatsJsonValue = _statsJson(
      cpuUserS: 1.5, // +0.5
      cpuSysS: 0.5, // +0.5 -> 1.0s of CPU over a 10s interval == 10%
      rssBytes: 120 * 1024 * 1024,
      obsTotal: 700, // +600
      voTotal: 700, // +600
    );
    monitor.sampleOnce();
    monitor.dispose();

    final files = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList();
    expect(files, hasLength(1));
    final lines = files.first.readAsLinesSync();
    expect(lines, hasLength(2));

    final first = jsonDecode(lines[0]) as Map<String, dynamic>;
    expect(first['cpu_pct'], 0.0);
    expect(first['rss_mb'], 100.0);
    expect(first['obs_total_frames_delta'], 0);
    expect(first['game'], 'league_of_legends');

    final second = jsonDecode(lines[1]) as Map<String, dynamic>;
    expect(second['cpu_pct'], 10.0);
    expect(second['rss_mb'], 120.0);
    expect(second['obs_total_frames'], 700);
    expect(second['obs_total_frames_delta'], 600);
    expect(second['vo_total_frames_delta'], 600);
    expect(second['obs_lagged_frames_delta'], 0);
    expect(second['vo_skipped_frames_delta'], 0);
    expect(second['game'], 'league_of_legends');
  });

  test('null engine still writes a line with zeroed stats and the active game',
      () {
    final monitor = PerfMonitor(
      engine: null,
      activeGameGetter: () => 'valorant',
      logsDir: tmp,
      now: () => DateTime(2026, 1, 1),
    );
    monitor.start();
    monitor.sampleOnce();
    monitor.dispose();

    final file = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'));
    final line = jsonDecode(file.single.readAsLinesSync().single)
        as Map<String, dynamic>;
    expect(line['cpu_pct'], 0.0);
    expect(line['rss_mb'], 0.0);
    expect(line['obs_total_frames'], 0);
    expect(line['game'], 'valorant');
  });

  test('start() prunes perf-*.jsonl files older than 14 days, leaves others',
      () {
    final now = DateTime(2026, 7, 18);
    final old = File(p.join(tmp.path, 'perf-old.jsonl'))
      ..writeAsStringSync('{}');
    old.setLastModifiedSync(now.subtract(const Duration(days: 20)));
    final recent = File(p.join(tmp.path, 'perf-recent.jsonl'))
      ..writeAsStringSync('{}');
    recent.setLastModifiedSync(now.subtract(const Duration(days: 2)));
    // Not a perf file — a stale one of these must never be touched by this
    // sweep (that's file_log.dart's job, over a different retention rule).
    final unrelated = File(p.join(tmp.path, 'rewind-session.log'))
      ..writeAsStringSync('x');
    unrelated.setLastModifiedSync(now.subtract(const Duration(days: 30)));

    final monitor = PerfMonitor(
      engine: null,
      activeGameGetter: () => null,
      logsDir: tmp,
      now: () => now,
    );
    monitor.start();
    monitor.dispose();

    expect(old.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
    expect(unrelated.existsSync(), isTrue);
  });

  test(
      'human summary logs at info when lagged/skipped deltas are non-zero, '
      'debug otherwise', () async {
    final engine = FakeCaptureEngine();
    final levels = <LogLevel?>[];
    final sub = talker.stream.listen((e) {
      if (e.message?.startsWith('perf:') ?? false) levels.add(e.logLevel);
    });
    addTearDown(sub.cancel);

    final monitor = PerfMonitor(
      engine: engine,
      activeGameGetter: () => null,
      logsDir: tmp,
      now: () => DateTime(2026, 1, 1),
    );
    monitor.start();

    // Baseline sample: no previous stats yet, so deltas are forced to 0 —
    // never notable regardless of the raw counters.
    engine.perfStatsJsonValue = _statsJson(obsTotal: 100);
    monitor.sampleOnce();
    // Healthy delta: no new lag/skip, low cpu.
    engine.perfStatsJsonValue = _statsJson(obsTotal: 200);
    monitor.sampleOnce();
    // Unhealthy: a new lagged frame since the last sample.
    engine.perfStatsJsonValue = _statsJson(obsTotal: 300, obsLagged: 5);
    monitor.sampleOnce();
    monitor.dispose();

    // talker.stream is a broadcast StreamController; add() delivers
    // asynchronously, so let a microtask turn pass before asserting.
    await Future<void>.delayed(Duration.zero);
    expect(levels, [LogLevel.debug, LogLevel.debug, LogLevel.info]);
  });
}
