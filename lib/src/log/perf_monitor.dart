import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../obs/capture_engine.dart';
import 'log.dart';

/// How many days' worth of perf-*.jsonl files to keep; older ones are
/// pruned at [start]. Same spirit as file_log.dart's log retention, but
/// age-based rather than count-based — a perf file is tiny (one line every
/// 10s) so "last 14 days" is a more useful cutoff than "last N sessions".
const _keepDays = 14;

/// Always-on, lightweight sampler for diagnosing "Rewind is straining the
/// machine" reports: Rewind's own CPU%/RSS, and — the actually load-bearing
/// signal — libobs's frame-health counters (lagged/skipped frames mean
/// capture can't keep up). Polls [CaptureEngine.perfStatsJson] every
/// [interval] (default 10s), appends one JSON line to
/// `<logsDir>/perf-<session>.jsonl` for offline analysis, and logs a compact
/// human summary via [talker] (info when something looks wrong, debug
/// otherwise, so a healthy session doesn't spam the visible log).
///
/// Constructed once in main.dart and never disposed — see [dispose]'s doc
/// for why that's fine.
class PerfMonitor {
  final CaptureEngine? _engine;
  final String? Function() _activeGameGetter;
  final Directory _logsDir;
  final Duration _interval;
  final DateTime Function() _now;

  Timer? _timer;
  File? _jsonlFile;

  // Previous sample's cumulative values, for computing this sample's deltas
  // (and CPU% from the CPU-seconds delta). Null until the first sample
  // lands, so that first line reports zero deltas rather than a spurious
  // rate computed against "since process start".
  double? _lastCpuUserS;
  double? _lastCpuSysS;
  int? _lastObsTotalFrames;
  int? _lastObsLaggedFrames;
  int? _lastVoTotalFrames;
  int? _lastVoSkippedFrames;

  /// Human-readable names for the shim's `thermal_state` 0..3 sentinel
  /// (macOS `NSProcessInfo.thermalState`); index-matched, no entry for -1
  /// ("unavailable" — never looked up, callers guard with `>= 0` first).
  static const _thermalStateNames = ['nominal', 'fair', 'serious', 'critical'];

  PerfMonitor({
    required CaptureEngine? engine,
    required String? Function() activeGameGetter,
    required Directory logsDir,
    Duration interval = const Duration(seconds: 10),
    DateTime Function() now = DateTime.now,
  })  : _engine = engine,
        _activeGameGetter = activeGameGetter,
        _logsDir = logsDir,
        _interval = interval,
        _now = now;

  /// Opens this session's JSONL file, prunes perf files older than
  /// [_keepDays], and begins periodic sampling. Idempotent — a second call
  /// is a no-op.
  void start() {
    if (_timer != null) return;
    _logsDir.createSync(recursive: true);
    _pruneOldFiles();

    final stamp =
        _now().toIso8601String().replaceAll(':', '-').split('.').first;
    _jsonlFile = File(p.join(_logsDir.path, 'perf-$stamp.jsonl'));

    _timer = Timer.periodic(_interval, (_) => sampleOnce());
  }

  /// Stops periodic sampling. Not called from main.dart today — the monitor
  /// is meant to run for the app's whole lifetime — but tests need it to
  /// tear down their fake timers.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _pruneOldFiles() {
    final cutoff = _now().subtract(const Duration(days: _keepDays));
    List<FileSystemEntity> existing;
    try {
      existing = _logsDir.listSync();
    } catch (_) {
      return;
    }
    for (final entry in existing) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith('perf-') || !name.endsWith('.jsonl')) continue;
      try {
        if (entry.lastModifiedSync().isBefore(cutoff)) entry.deleteSync();
      } catch (_) {
        // Never let a stale/locked file stop the sweep or the sampler.
      }
    }
  }

  /// Takes one sample right now: reads [CaptureEngine.perfStatsJson],
  /// computes deltas/CPU% against the previous sample, appends a JSONL line
  /// and logs the human summary. Called by the periodic timer in [start];
  /// also public so tests can trigger samples deterministically instead of
  /// waiting on real wall-clock time between [Timer] ticks.
  void sampleOnce() {
    final json = _engine?.perfStatsJson();
    Map<String, dynamic>? stats;
    if (json != null) {
      try {
        stats = jsonDecode(json) as Map<String, dynamic>;
      } catch (err, stack) {
        talker.handle(err, stack);
      }
    }

    final cpuUserS = (stats?['cpu_user_s'] as num?)?.toDouble() ?? 0;
    final cpuSysS = (stats?['cpu_sys_s'] as num?)?.toDouble() ?? 0;
    final rssBytes = (stats?['rss_bytes'] as num?)?.toInt() ?? 0;
    final obsTotal = (stats?['obs_total_frames'] as num?)?.toInt() ?? 0;
    final obsLagged = (stats?['obs_lagged_frames'] as num?)?.toInt() ?? 0;
    final voTotal = (stats?['vo_total_frames'] as num?)?.toInt() ?? 0;
    final voSkipped = (stats?['vo_skipped_frames'] as num?)?.toInt() ?? 0;
    // The shim reports -1 for all three when unavailable (stub mode, an old
    // shim build predating these fields, or — gpu_util_pct/thermal_state —
    // a non-macOS platform); a missing key parses the same way via `??` so
    // "absent" and "explicit -1" are handled identically below.
    final obsRenderAvgMs =
        (stats?['obs_render_avg_ms'] as num?)?.toDouble() ?? -1;
    final gpuUtilPct = (stats?['gpu_util_pct'] as num?)?.toInt() ?? -1;
    final thermalState = (stats?['thermal_state'] as num?)?.toInt() ?? -1;

    var cpuPct = 0.0;
    var obsTotalDelta = 0;
    var obsLaggedDelta = 0;
    var voTotalDelta = 0;
    var voSkippedDelta = 0;
    if (_lastCpuUserS != null) {
      final cpuDeltaS = (cpuUserS - _lastCpuUserS!) + (cpuSysS - _lastCpuSysS!);
      final intervalS =
          _interval.inMicroseconds / Duration.microsecondsPerSecond;
      if (intervalS > 0) cpuPct = (cpuDeltaS / intervalS) * 100;
      obsTotalDelta = obsTotal - _lastObsTotalFrames!;
      obsLaggedDelta = obsLagged - _lastObsLaggedFrames!;
      voTotalDelta = voTotal - _lastVoTotalFrames!;
      voSkippedDelta = voSkipped - _lastVoSkippedFrames!;
    }
    _lastCpuUserS = cpuUserS;
    _lastCpuSysS = cpuSysS;
    _lastObsTotalFrames = obsTotal;
    _lastObsLaggedFrames = obsLagged;
    _lastVoTotalFrames = voTotal;
    _lastVoSkippedFrames = voSkipped;

    final game = _activeGameGetter();
    final rssMb = rssBytes / (1024 * 1024);
    final ts = _now().toIso8601String();

    final line = jsonEncode({
      'ts': ts,
      'cpu_pct': double.parse(cpuPct.toStringAsFixed(1)),
      'rss_mb': double.parse(rssMb.toStringAsFixed(1)),
      'obs_total_frames': obsTotal,
      'obs_total_frames_delta': obsTotalDelta,
      'obs_lagged_frames': obsLagged,
      'obs_lagged_frames_delta': obsLaggedDelta,
      'vo_total_frames': voTotal,
      'vo_total_frames_delta': voTotalDelta,
      'vo_skipped_frames': voSkipped,
      'vo_skipped_frames_delta': voSkippedDelta,
      // Omitted (not written as null) when the shim reports -1/unavailable
      // — keeps a healthy-platform JSONL free of a field that would never
      // carry data there (Windows/Linux gpu_util_pct and thermal_state
      // today), while still round-tripping cleanly for offline analysis
      // tools that just check `containsKey`.
      if (obsRenderAvgMs >= 0)
        'obs_render_avg_ms': double.parse(obsRenderAvgMs.toStringAsFixed(2)),
      if (gpuUtilPct >= 0) 'gpu_util_pct': gpuUtilPct,
      if (thermalState >= 0) 'thermal_state': thermalState,
      'game': game,
    });
    try {
      _jsonlFile?.writeAsStringSync('$line\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // Never let logging take the app down (mirrors file_log.dart).
    }

    final extras = <String>[
      if (obsRenderAvgMs >= 0) 'render ${obsRenderAvgMs.toStringAsFixed(2)} ms',
      if (gpuUtilPct >= 0) 'gpu $gpuUtilPct%',
      if (thermalState >= 0 && thermalState < _thermalStateNames.length)
        'thermal ${_thermalStateNames[thermalState]}',
    ];
    final humanLine = 'perf: cpu ${cpuPct.round()}% · rss ${rssMb.round()} MB '
        '· frames $obsTotal (+$obsTotalDelta) · lagged $obsLagged '
        '(+$obsLaggedDelta) · skipped $voSkipped'
        '${extras.isEmpty ? '' : ' · ${extras.join(' · ')}'}'
        ' · game ${game ?? 'none'}';
    // Only escalate to info when there's something worth seeing without
    // opening the JSONL: a new lag/skip since last sample, heavy CPU, or the
    // machine is thermally throttling (>= 2/serious) — the exact mechanism
    // behind "input delay 20 minutes in" reports this field exists to catch.
    // Otherwise this would log 6x/minute even on a perfectly healthy session.
    final notable = obsLaggedDelta != 0 ||
        voSkippedDelta != 0 ||
        cpuPct > 50 ||
        thermalState >= 2;
    if (notable) {
      talker.info(humanLine);
    } else {
      talker.debug(humanLine);
    }
  }
}
