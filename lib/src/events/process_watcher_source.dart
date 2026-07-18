import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'game_event.dart';
import 'game_event_source.dart';

/// Lists the names of currently-running processes.
///
/// Abstracted so [ProcessWatcherSource] can be tested without shelling out,
/// and so the OS-specific listing strategy stays in one place.
abstract class ProcessLister {
  Future<List<String>> runningProcessNames();
}

/// Default [ProcessLister]: asks the OS for the running process list.
///
/// This reads the OS-provided process *list* only (name/executable, not
/// memory contents) — the same information `ps`/`tasklist`/Activity
/// Monitor/Task Manager expose to any user. Per docs/COMPLIANCE.md this is a
/// sanctioned source: it is not game-memory access, DLL injection/hooking,
/// or packet capture, so it is anti-cheat safe.
class SystemProcessLister implements ProcessLister {
  const SystemProcessLister();

  @override
  Future<List<String>> runningProcessNames() async {
    if (Platform.isWindows) {
      final res = await Process.run('tasklist', ['/fo', 'csv', '/nh']);
      if (res.exitCode != 0) return const [];
      final out = res.stdout.toString();
      final names = <String>[];
      for (final line in const LineSplitter().convert(out)) {
        if (line.trim().isEmpty) continue;
        final fields = _parseCsvLine(line);
        if (fields.isEmpty) continue;
        names.add(_basename(fields.first));
      }
      return names;
    }

    // macOS / Linux.
    final res = await Process.run('ps', ['-axo', 'comm=']);
    if (res.exitCode != 0) return const [];
    final out = res.stdout.toString();
    return const LineSplitter()
        .convert(out)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map(_basename)
        .toList();
  }

  /// Minimal CSV field parser sufficient for `tasklist /fo csv` output,
  /// where fields are double-quoted and comma-separated.
  static List<String> _parseCsvLine(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ',' && !inQuotes) {
        fields.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    fields.add(buf.toString());
    return fields;
  }

  static String _basename(String pathOrName) {
    final normalized = pathOrName.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash == -1 ? normalized : normalized.substring(slash + 1);
  }
}

/// Shares one process-list snapshot between many watcher sources.
///
/// [GameRegistry] polls every source each supervision tick; with a dozen
/// catalog sources each shelling out its own `ps`/`tasklist`, that's a
/// steady stream of process spawns forever. Wrapping ONE [SystemProcessLister]
/// in this cache and injecting it into every source collapses a whole tick's
/// lookups into a single spawn ([ttl] just needs to sit below the tick
/// interval so each tick still gets a fresh snapshot).
class CachingProcessLister implements ProcessLister {
  final ProcessLister _inner;
  final Duration ttl;

  List<String>? _cached;
  DateTime? _fetchedAt;

  CachingProcessLister(this._inner,
      {this.ttl = const Duration(milliseconds: 1500)});

  @override
  Future<List<String>> runningProcessNames() async {
    final cached = _cached;
    final at = _fetchedAt;
    if (cached != null && at != null && DateTime.now().difference(at) < ttl) {
      return cached;
    }
    final fresh = await _inner.runningProcessNames();
    _cached = fresh;
    _fetchedAt = DateTime.now();
    return fresh;
  }
}

/// Detects a user-chosen application by checking the OS process list.
///
/// This exists purely for *detection* (so Rewind can auto-apply a saved
/// capture profile when the app relaunches); it has no vendor event feed, so
/// [events] is always empty. A future per-game integration with a sanctioned
/// vendor API (see docs/COMPLIANCE.md) would replace this source for that
/// specific game — this watcher is the generic fallback for "any app".
class ProcessWatcherSource implements GameEventSource {
  ProcessWatcherSource({
    required this.gameId,
    required this.displayName,
    required this.processMatch,
    ProcessLister? lister,
    this.countsAsPlaying = true,
  }) : _lister = lister ?? const SystemProcessLister();

  @override
  final String gameId;

  @override
  final String displayName;

  /// Case-insensitive substring matched against running process/executable
  /// names (basename only — paths are normalized before matching).
  final String processMatch;

  @override
  final bool countsAsPlaying;

  final ProcessLister _lister;
  final _controller = StreamController<GameEvent>.broadcast();
  bool _started = false;

  @override
  Future<bool> isGameRunning() async {
    try {
      final names = await _lister.runningProcessNames();
      final needle = processMatch.toLowerCase();
      return names.any((n) => n.toLowerCase().contains(needle));
    } catch (_) {
      return false; // Never let a listing failure surface as "running".
    }
  }

  @override
  Stream<GameEvent> events() => _controller.stream;

  @override
  Future<void> start() async {
    _started = true;
  }

  @override
  Future<void> stop() async {
    _started = false;
  }

  /// Whether [start] has been called without a matching [stop].
  bool get isStarted => _started;
}
