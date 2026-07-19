import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/steam_account_locator.dart';
import 'package:rewind/src/events/steam_stats_watcher.dart';
import 'package:rewind/src/settings/app_settings.dart';

/// A minimal binary-VDF writer -- see steam_stats_vdf_test.dart's identical
/// helper for why this exists (synthetic fixtures only, never a real file).
class _VdfBuilder {
  final BytesBuilder _b = BytesBuilder();

  void _key(String key) {
    _b.add(utf8.encode(key));
    _b.addByte(0);
  }

  void nestedStart(String key) {
    _b.addByte(0x00);
    _key(key);
  }

  void end() => _b.addByte(0x08);

  void stringEntry(String key, String value) {
    _b.addByte(0x01);
    _key(key);
    _b.add(utf8.encode(value));
    _b.addByte(0);
  }

  void int32Entry(String key, int value) {
    _b.addByte(0x02);
    _key(key);
    final bd = ByteData(4)..setInt32(0, value, Endian.little);
    _b.add(bd.buffer.asUint8List());
  }

  Uint8List build() => _b.toBytes();
}

Uint8List _statsBytes(Map<int, int> achievementTimes) {
  final b = _VdfBuilder()
    ..nestedStart('cache')
    ..nestedStart('PendingChanges')
    ..nestedStart('data')
    ..nestedStart('AchievementTimes');
  for (final entry in achievementTimes.entries) {
    b.int32Entry('${entry.key}', entry.value);
  }
  b
    ..end()
    ..end()
    ..end()
    ..end();
  return b.build();
}

Uint8List _schemaBytes(Map<int, String> displayNames) {
  final b = _VdfBuilder()
    ..nestedStart('1234560')
    ..nestedStart('stats')
    ..nestedStart('0')
    ..int32Entry('type', 4)
    ..nestedStart('bits');
  for (final entry in displayNames.entries) {
    b
      ..nestedStart('${entry.key}')
      ..stringEntry('name', 'API_${entry.key}')
      ..nestedStart('display')
      ..nestedStart('name')
      ..stringEntry('english', entry.value)
      ..end()
      ..end()
      ..end();
  }
  b
    ..end()
    ..end()
    ..end()
    ..end();
  return b.build();
}

/// An in-memory fake filesystem for the watcher's three injected disk seams
/// -- directory listing, mtime stat, and byte reads -- keyed on paths built
/// with the SAME `p.join` calls production uses, so behavior is identical
/// regardless of which OS actually runs the test.
class _FakeFs {
  final Map<String, List<String>> _dirNames = {};
  final Map<String, DateTime> _mtimes = {};
  final Map<String, Uint8List> _contents = {};

  Future<List<String>> listDirNames(String dirPath) async =>
      _dirNames[dirPath] ?? const [];
  Future<DateTime?> statModified(String path) async => _mtimes[path];
  Future<Uint8List?> readBytes(String path) async => _contents[path];

  void putFile(String dirPath, String name, Uint8List bytes, DateTime mtime) {
    final list = _dirNames.putIfAbsent(dirPath, () => []);
    if (!list.contains(name)) list.add(name);
    final path = p.join(dirPath, name);
    _contents[path] = bytes;
    _mtimes[path] = mtime;
  }

  void removeFile(String dirPath, String name) {
    _dirNames[dirPath]?.remove(name);
    final path = p.join(dirPath, name);
    _contents.remove(path);
    _mtimes.remove(path);
  }
}

void main() {
  late AppSettings settings;
  late _FakeFs fs;
  late List<SteamTree> trees;
  late SteamStatsWatcher watcher;
  late List<GameEvent> emitted;
  late DateTime fakeNow;

  const tree1Root = '/fake/native/Steam';
  const tree1Id3 = 22202;
  final tree1StatsDir = p.join(tree1Root, 'appcache', 'stats');

  const tree2Root = '/fake/crossover/Steam';
  const tree2Id3 = 99001;

  setUp(() {
    settings = AppSettings();
    fs = _FakeFs();
    trees = [
      const SteamTree(rootPath: tree1Root, accountId3s: [tree1Id3]),
    ];
    fakeNow = DateTime.utc(2026, 7, 19, 12, 0, 0);
    watcher = SteamStatsWatcher(
      settings: settings,
      locateTrees: () async => trees,
      listDirNames: fs.listDirNames,
      statModified: fs.statModified,
      readBytes: fs.readBytes,
      now: () => fakeNow,
    );
    emitted = [];
    watcher.events().listen(emitted.add);
  });

  tearDown(() => watcher.stop());

  test('gameId/displayName', () {
    expect(watcher.gameId, 'steam');
    expect(watcher.displayName, 'Steam');
  });

  test(
      'isGameRunning always answers false -- never activates through '
      'GameRegistry\'s normal tick', () async {
    expect(await watcher.isGameRunning(), isFalse);
  });

  test('processMatch is null (no OS process of its own to match)', () {
    expect(watcher.processMatch, isNull);
  });

  group('discovery', () {
    test('finds a fake tree layout via the injected locator', () async {
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow();
      expect(watcher.status.value,
          'Watching — achievements will clip automatically (1 Steam account)');
    });

    test('no trees found: "No Steam installation found"', () async {
      trees = const [];
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow();
      expect(
          watcher.status.value,
          'No Steam installation found — install Steam and sign in to '
          'enable this.');
      expect(emitted, isEmpty);
    });

    test('multiple trees are watched simultaneously, not first-match-wins',
        () async {
      trees = [
        const SteamTree(rootPath: tree1Root, accountId3s: [tree1Id3]),
        const SteamTree(rootPath: tree2Root, accountId3s: [tree2Id3]),
      ];
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow();
      expect(watcher.status.value,
          'Watching — achievements will clip automatically (2 Steam accounts)');
    });
  });

  group('seeding', () {
    test('first sighting of a stats file emits nothing', () async {
      fs.putFile(
          tree1StatsDir,
          'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: fakeNow.millisecondsSinceEpoch ~/ 1000}),
          DateTime(2026, 7, 19, 11, 0));

      await watcher.runDiscoveryNow();
      await watcher.runWatchNow();

      expect(emitted, isEmpty,
          reason: 'first poll of a file only SEEDS -- the 44 MB lesson');
      expect(watcher.status.value,
          'Watching — achievements will clip automatically (1 Steam account)');
    });

    test('an unchanged mtime on a later tick is never re-parsed', () async {
      final bytes = _statsBytes({17: 1700000000});
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin', bytes,
          DateTime(2026, 7, 19, 11, 0));
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow(); // seeds
      await watcher.runWatchNow(); // same mtime -- must not re-seed/emit
      expect(emitted, isEmpty);
    });
  });

  group('unlock diff emission', () {
    Future<void> seedEmpty() async {
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes(const {}), DateTime(2026, 7, 19, 11, 0));
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow();
    }

    test('a new unlock after seeding emits with the schema display name',
        () async {
      await seedEmpty();

      fs.putFile(tree1StatsDir, 'UserGameStatsSchema_730.bin',
          _schemaBytes({17: 'Winner Winner'}), DateTime(2026, 7, 19, 11, 0));
      final unlockEpoch = fakeNow.millisecondsSinceEpoch ~/ 1000;
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: unlockEpoch}), DateTime(2026, 7, 19, 11, 5));

      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(1));
      final e = emitted.single;
      expect(e.kind, GameEventKind.achievement);
      expect(e.gameId, 'steam:730');
      expect(e.meta['label'], 'Winner Winner');
      expect(e.meta['appId'], 730);
      expect(e.meta['index'], 17);
    });

    test('resolveGameId attributes the clip to the currently-detected game',
        () async {
      watcher.resolveGameId = () => 'cs2_live';
      await seedEmpty();
      final unlockEpoch = fakeNow.millisecondsSinceEpoch ~/ 1000;
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: unlockEpoch}), DateTime(2026, 7, 19, 11, 5));
      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);
      expect(emitted.single.gameId, 'cs2_live');
    });

    test(
        'a missing schema fetch still emits, falling back to a numbered '
        'placeholder', () async {
      await seedEmpty();
      final unlockEpoch = fakeNow.millisecondsSinceEpoch ~/ 1000;
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: unlockEpoch}), DateTime(2026, 7, 19, 11, 5));
      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);
      expect(emitted.single.meta['label'], 'Achievement #17');
    });

    test('an already-unlocked achievement never re-emits (tick after tick)',
        () async {
      await seedEmpty();
      final unlockEpoch = fakeNow.millisecondsSinceEpoch ~/ 1000;
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: unlockEpoch}), DateTime(2026, 7, 19, 11, 5));
      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(1));

      // Same file, same content, same mtime again -- must not re-emit.
      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(1));
    });

    test('multiple simultaneous new unlocks in one file all emit', () async {
      await seedEmpty();
      final unlockEpoch = fakeNow.millisecondsSinceEpoch ~/ 1000;
      fs.putFile(
          tree1StatsDir,
          'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: unlockEpoch, 19: unlockEpoch}),
          DateTime(2026, 7, 19, 11, 5));
      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(2));
      expect(emitted.map((e) => e.meta['index']), containsAll([17, 19]));
    });

    test('a file for an id3 not known to the tree is ignored', () async {
      fs.putFile(tree1StatsDir, 'UserGameStats_9999999_730.bin',
          _statsBytes({17: 1700000000}), DateTime(2026, 7, 19, 11, 0));
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow();
      // Still reports watching (the known account), but the stray file's
      // "unlock" was never even seeded, let alone emitted.
      expect(watcher.status.value,
          'Watching — achievements will clip automatically (1 Steam account)');
      expect(emitted, isEmpty);
    });
  });

  group('freshness guard', () {
    test('an unlock timestamp older than the freshness window never emits',
        () async {
      await watcher.runDiscoveryNow();
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes(const {}), DateTime(2026, 7, 19, 11, 0));
      await watcher.runWatchNow(); // seed with nothing unlocked

      // A stale unlock -- 20 minutes before `fakeNow`, outside the default
      // 10-minute freshness window -- must never clip even though it's
      // "new" to this watcher's own bookkeeping.
      final staleEpoch = fakeNow
              .subtract(const Duration(minutes: 20))
              .millisecondsSinceEpoch ~/
          1000;
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: staleEpoch}), DateTime(2026, 7, 19, 11, 5));
      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isEmpty);
    });

    test('an unlock timestamp inside the window does emit', () async {
      await watcher.runDiscoveryNow();
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes(const {}), DateTime(2026, 7, 19, 11, 0));
      await watcher.runWatchNow();

      final freshEpoch =
          fakeNow.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
              1000;
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: freshEpoch}), DateTime(2026, 7, 19, 11, 5));
      await watcher.runWatchNow();
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(1));
    });
  });

  group('malformed/truncated files', () {
    test('a garbage file is skipped silently and retried next tick', () async {
      await watcher.runDiscoveryNow();
      final garbage =
          Uint8List.fromList(List.generate(30, (i) => (i * 71) % 256));
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin', garbage,
          DateTime(2026, 7, 19, 11, 0));

      await watcher.runWatchNow(); // garbage -- must not throw or crash
      expect(emitted, isEmpty);

      // Steam finishes the write on the next tick -- now valid bytes with a
      // new mtime. Since the garbage tick never recorded any state, this
      // counts as the file's first REAL sighting and only seeds.
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: 1700000000}), DateTime(2026, 7, 19, 11, 1));
      await watcher.runWatchNow();
      expect(emitted, isEmpty, reason: 'still just seeding, not diffing');
    });
  });

  group('the clipSteamAchievements toggle', () {
    test('off: status is null and unlocks are tracked but never emitted',
        () async {
      settings.clipSteamAchievements = false;
      await watcher.runDiscoveryNow();
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes(const {}), DateTime(2026, 7, 19, 11, 0));
      await watcher.runWatchNow(); // seed
      expect(watcher.status.value, isNull);

      final unlockEpoch = fakeNow.millisecondsSinceEpoch ~/ 1000;
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: unlockEpoch}), DateTime(2026, 7, 19, 11, 5));
      await watcher.runWatchNow();
      expect(emitted, isEmpty);
      expect(watcher.status.value, isNull);

      // Turning it back on must not replay the tracked unlock as "new".
      settings.clipSteamAchievements = true;
      await watcher.runWatchNow();
      expect(emitted, isEmpty);
    });

    test(
        'off with no Steam installation: status is still null, not '
        '"No Steam installation found"', () async {
      settings.clipSteamAchievements = false;
      trees = const [];
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow();
      expect(watcher.status.value, isNull);
    });
  });

  group('stop() resets state', () {
    test('re-seeds instead of replaying after stop/start', () async {
      fs.putFile(tree1StatsDir, 'UserGameStats_${tree1Id3}_730.bin',
          _statsBytes({17: 1700000000}), DateTime(2026, 7, 19, 11, 0));
      await watcher.runDiscoveryNow();
      await watcher.runWatchNow(); // seeds 17 as already-unlocked
      await watcher.stop();

      await watcher.start();
      expect(emitted, isEmpty);
      await watcher.stop();
    });
  });
}
