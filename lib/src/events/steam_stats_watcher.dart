import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../log/log.dart';
import '../settings/app_settings.dart';
import 'game_event.dart';
import 'game_event_source.dart';
import 'steam_account_locator.dart';
import 'steam_stats_vdf.dart';

/// One tracked `UserGameStats_<id3>_<appid>.bin` file: its last-seen mtime
/// (the cheap `stat()` gate -- re-parsing only happens when this changes)
/// and the `AchievementTimes` snapshot from the last successful parse,
/// diffed against on the next change to find newly-unlocked indices.
class _StatsFileState {
  DateTime mtime;
  Map<int, DateTime> snapshot;
  _StatsFileState({required this.mtime, required this.snapshot});
}

/// Detects Steam achievement unlocks entirely from Steam's own LOCAL stats
/// cache -- no Web API key, no network, no account required beyond what the
/// Steam client itself already logged in with. See docs/COMPLIANCE.md's
/// Steam entry for the maintainer's read-only rule this class must never
/// violate (it must NEVER write any of the files it watches), and
/// `steam_stats_vdf.dart` for the tolerant binary-VDF parsing this relies
/// on.
///
/// This REPLACES `SteamAchievementWatcher` as the thing `source_builder.
/// dart` constructs (see that file's doc) -- the web watcher stays in the
/// tree, unbuilt, for possible future enrichment (a display name / global
/// stat the local cache doesn't carry), but the credential-gated trigger
/// path is retired in favor of this always-on, keyless one.
///
/// Two tiers of polling, both re-entrancy-guarded like
/// `SteamAchievementWatcher`'s two-tier design (they don't share a base
/// class -- see that class's doc for the YAGNI reasoning, which applies here
/// too: a THIRD Steam-shaped source with yet another activation/status
/// contract):
///  1. **Discovery** ([discoveryInterval], default 60 s): which Steam
///     installs ("trees") exist on this machine, and which accounts are
///     logged into each -- see `SteamTree`/`locateSteamTrees`. ALL
///     discovered trees are watched simultaneously (native Steam and every
///     CrossOver bottle are fully independent clients with separate
///     accounts/libraries).
///  2. **Watch** ([watchInterval], default 3 s): per discovered tree, list
///     `appcache/stats/` and `stat()` every `UserGameStats_<id3>_<appid>.bin`
///     belonging to a known account -- cheap enough to run constantly.
///     Reading + parsing a file's bytes only happens when its mtime changed
///     since the last look.
///
/// The first sighting of a stats file SEEDS its `AchievementTimes` snapshot
/// and emits nothing -- the same "44 MB lesson" as `SteamAchievementWatcher`
/// and `LeagueEventWatcher`: replaying a whole unlock history as clips the
/// moment Rewind starts watching a game would be a disaster. On top of
/// seeding, [freshnessWindow] is a second guard: an unlock timestamp older
/// than that is never clipped even if it's "new" to this watcher's
/// bookkeeping -- belt-and-suspenders against e.g. a Steam Cloud sync
/// rewriting an old unlock's file with a fresh mtime.
///
/// [isGameRunning] always answers false, same reasoning as
/// `SteamAchievementWatcher`: this source never "activates" through
/// `GameRegistry`'s normal tick; `main.dart` starts it directly at startup
/// instead (see `wireSteamWatchers`' doc, generalized to this type).
class SteamStatsWatcher implements GameEventSource {
  final AppSettings settings;
  final Duration discoveryInterval;
  final Duration watchInterval;
  final Duration freshnessWindow;

  final Future<List<SteamTree>> Function() _locateTrees;
  final Future<List<String>> Function(String dirPath) _listDirNames;
  final Future<DateTime?> Function(String path) _statModified;
  final Future<Uint8List?> Function(String path) _readBytes;
  final DateTime Function() _now;

  /// Resolves the currently-active DETECTED game -- same contract as
  /// `SteamAchievementWatcher.resolveGameId`; set by `main.dart` once the
  /// coordinator exists. Null (the default) falls back to `steam:<appid>`.
  String? Function()? resolveGameId;

  SteamStatsWatcher({
    required this.settings,
    this.discoveryInterval = const Duration(seconds: 60),
    this.watchInterval = const Duration(seconds: 3),
    this.freshnessWindow = const Duration(minutes: 10),
    Future<List<SteamTree>> Function()? locateTrees,
    Future<List<String>> Function(String dirPath)? listDirNames,
    Future<DateTime?> Function(String path)? statModified,
    Future<Uint8List?> Function(String path)? readBytes,
    DateTime Function()? now,
    this.resolveGameId,
  })  : _locateTrees = locateTrees ?? locateSteamTreesOnThisMachine,
        _listDirNames = listDirNames ?? _listDirNamesOnDisk,
        _statModified = statModified ?? _statModifiedOnDisk,
        _readBytes = readBytes ?? _readBytesOnDisk,
        _now = now ?? DateTime.now;

  final _controller = StreamController<GameEvent>.broadcast();

  /// UI-facing status line (`SettingsScreen`'s Steam tab) -- see this
  /// class's doc for the states it cycles through.
  final ValueNotifier<String?> status = ValueNotifier(null);

  Timer? _discoveryTimer;
  Timer? _watchTimer;
  bool _discovering = false;
  bool _watching = false;

  List<SteamTree> _trees = const [];

  /// Keyed by the stats file's full path -- unique across every tree, so
  /// one flat map covers all of them without a nested per-tree structure.
  final Map<String, _StatsFileState> _fileStates = {};

  /// Achievement index -> display name, cached per appid (parsed lazily,
  /// the first time an unlock for that appid is actually seen) -- mirrors
  /// `SteamAchievementWatcher._schemaCache`.
  final Map<int, Map<int, String>> _schemaCache = {};

  static final _statsFilePattern = RegExp(r'^UserGameStats_(\d+)_(\d+)\.bin$');

  @override
  String get gameId => 'steam';

  @override
  String get displayName => 'Steam';

  /// Always false -- see this class's doc for why (mirrors
  /// `SteamAchievementWatcher.isGameRunning`'s reasoning exactly).
  @override
  Future<bool> isGameRunning() async => false;

  /// Moot given [isGameRunning] is always false -- left at the interface
  /// default, same rationale as `SteamAchievementWatcher.countsAsPlaying`.
  @override
  bool get countsAsPlaying => true;

  @override
  String? get processMatch => null;

  @override
  Stream<GameEvent> events() => _controller.stream;

  @override
  Future<void> start() async {
    if (_discoveryTimer != null) return; // already started -- idempotent
    await runDiscoveryNow();
    _discoveryTimer ??=
        Timer.periodic(discoveryInterval, (_) => unawaited(runDiscoveryNow()));
    _watchTimer ??=
        Timer.periodic(watchInterval, (_) => unawaited(runWatchNow()));
  }

  @override
  Future<void> stop() async {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _watchTimer?.cancel();
    _watchTimer = null;
    _trees = const [];
    _fileStates.clear();
    _schemaCache.clear();
    status.value = null;
  }

  /// Visible for tests: one discovery cycle, exactly what the periodic timer
  /// runs.
  Future<void> runDiscoveryNow() async {
    if (_discovering) return;
    _discovering = true;
    try {
      _trees = await _locateTrees();
    } catch (err, stack) {
      talker.handle(err, stack);
      _trees = const [];
    } finally {
      _discovering = false;
    }
  }

  /// Visible for tests: one watch cycle, exactly what the periodic timer
  /// runs.
  Future<void> runWatchNow() async {
    if (_watching) return;
    _watching = true;
    try {
      await _doWatchTick();
    } finally {
      _watching = false;
    }
  }

  Future<void> _doWatchTick() async {
    if (_trees.isEmpty) {
      status.value =
          settings.clipSteamAchievements ? 'No Steam installation found' : null;
      return;
    }

    var accountCount = 0;
    for (final tree in _trees) {
      accountCount += tree.accountId3s.length;
      final statsDir = p.join(tree.rootPath, 'appcache', 'stats');
      List<String> names;
      try {
        names = await _listDirNames(statsDir);
      } catch (err, stack) {
        talker.handle(err, stack);
        continue;
      }
      for (final name in names) {
        final match = _statsFilePattern.firstMatch(name);
        if (match == null) continue;
        final id3 = int.tryParse(match.group(1)!);
        final appId = int.tryParse(match.group(2)!);
        if (id3 == null || appId == null) continue;
        if (!tree.accountId3s.contains(id3)) continue; // not a known account
        await _processStatsFile(p.join(statsDir, name), statsDir, appId);
      }
    }

    status.value = settings.clipSteamAchievements
        ? 'Watching ($accountCount Steam account${accountCount == 1 ? '' : 's'})'
        : null;
  }

  Future<void> _processStatsFile(
      String path, String statsDir, int appId) async {
    DateTime? mtime;
    try {
      mtime = await _statModified(path);
    } catch (err, stack) {
      talker.handle(err, stack);
      return;
    }
    if (mtime == null) return; // vanished mid-tick; retry next tick

    final existing = _fileStates[path];
    if (existing != null && existing.mtime == mtime) {
      return; // unchanged since last look -- nothing to parse
    }

    Uint8List? bytes;
    try {
      bytes = await _readBytes(path);
    } catch (err, stack) {
      talker.handle(err, stack);
      return;
    }
    if (bytes == null) return; // vanished/unreadable; retry next tick

    final parsed = parseAchievementUnlockTimes(bytes);
    if (parsed == null) {
      // Malformed/truncated -- Steam mid-write. Skip silently and retry
      // next tick; deliberately does NOT update `_fileStates[path]`, so a
      // still-changing mtime keeps re-triggering a re-read until it settles.
      return;
    }

    if (existing == null) {
      // First sighting of this file: SEED, emit nothing -- the 44 MB
      // lesson applies here exactly like `SteamAchievementWatcher`'s.
      _fileStates[path] = _StatsFileState(mtime: mtime, snapshot: parsed);
      return;
    }

    final previous = existing.snapshot;
    for (final entry in parsed.entries) {
      final index = entry.key;
      final unlockTime = entry.value;
      final prevTime = previous[index];
      final wasZero = prevTime != null && prevTime.millisecondsSinceEpoch == 0;
      // New index present, OR previously-present-but-zero now has a real
      // timestamp -- see the class doc's freshness-guard note for why a
      // zero placeholder can appear at all.
      final isNewUnlock = (prevTime == null || wasZero) &&
          unlockTime.millisecondsSinceEpoch != 0;
      if (!isNewUnlock) continue;

      if (_now().toUtc().difference(unlockTime.toUtc()) > freshnessWindow) {
        continue; // stale -- e.g. a cloud-sync rewrite of an old unlock
      }

      // Fail closed on the toggle same as `SteamAchievementWatcher`: the
      // snapshot below still records this as known/seen either way, so
      // re-enabling the toggle later doesn't replay it as "new".
      if (settings.clipSteamAchievements) {
        final label = await _displayNameFor(statsDir, appId, index);
        talker.info('Steam: achievement unlocked ($label, appid $appId)');
        _controller.add(GameEvent(
          gameId: resolveGameId?.call() ?? 'steam:$appId',
          kind: GameEventKind.achievement,
          meta: {'label': label, 'appId': appId, 'index': index},
        ));
      }
    }

    _fileStates[path] = _StatsFileState(mtime: mtime, snapshot: parsed);
  }

  /// The achievement's real display name from the sibling schema file
  /// (cached per appid), falling back to a numbered placeholder if the
  /// schema doesn't carry a name for this index -- a schema hiccup, or the
  /// index-space assumption in `steam_stats_vdf.dart`'s doc not holding for
  /// some game, must never withhold the clip itself, just its prettiest
  /// label.
  Future<String> _displayNameFor(String statsDir, int appId, int index) async {
    final cached = _schemaCache[appId];
    final names = cached ?? await _loadSchema(statsDir, appId);
    return names[index] ?? 'Achievement #$index';
  }

  Future<Map<int, String>> _loadSchema(String statsDir, int appId) async {
    var names = const <int, String>{};
    try {
      final bytes =
          await _readBytes(p.join(statsDir, 'UserGameStatsSchema_$appId.bin'));
      if (bytes != null) names = parseAchievementDisplayNames(bytes);
    } catch (err, stack) {
      talker.handle(err, stack);
    }
    _schemaCache[appId] = names;
    return names;
  }
}

Future<List<String>> _listDirNamesOnDisk(String dirPath) async {
  try {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final entries = await dir.list().toList();
    return [
      for (final entry in entries)
        if (entry is File) p.basename(entry.path),
    ];
  } catch (_) {
    return const [];
  }
}

Future<DateTime?> _statModifiedOnDisk(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return (await file.stat()).modified;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _readBytesOnDisk(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}
