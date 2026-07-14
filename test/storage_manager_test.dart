import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/settings/app_settings.dart';

Clip _clip(String path, DateTime at, int bytes, {bool protected = false}) =>
    Clip(
      path: path,
      gameId: 'test',
      event: GameEventKind.kill,
      createdAt: at,
      sizeBytes: bytes,
      protected: protected,
    );

void main() {
  test('budget pruning deletes oldest unprotected first, keeps protected',
      () async {
    final lib =
        ClipLibrary(clipsDir: Directory.systemTemp.createTempSync('rewind_sm'));
    final now = DateTime(2026, 1, 1, 12);
    // 3 clips of 10 bytes each = 30; budget 15 -> must drop to <=15.
    lib.add(_clip('a', now.subtract(const Duration(hours: 3)), 10)); // oldest
    lib.add(_clip('b', now.subtract(const Duration(hours: 2)), 10,
        protected: true));
    lib.add(_clip('c', now.subtract(const Duration(hours: 1)), 10)); // newest

    final mgr =
        StorageManager(lib, policy: const RetentionPolicy(maxBytes: 15));
    final deleted = await mgr.enforce(now: now);

    // 'a' (oldest, unprotected) deleted; 'b' protected must survive.
    expect(deleted.map((c) => c.path), contains('a'));
    expect(lib.all.any((c) => c.path == 'b'), isTrue);
  });

  test('protected clips are never removed by age policy', () async {
    final lib =
        ClipLibrary(clipsDir: Directory.systemTemp.createTempSync('rewind_sm'));
    final now = DateTime(2026, 1, 1, 12);
    lib.add(_clip('old', now.subtract(const Duration(days: 30)), 10,
        protected: true));

    final mgr = StorageManager(lib,
        policy: const RetentionPolicy(maxAge: Duration(days: 7)));
    final deleted = await mgr.enforce(now: now);

    expect(deleted, isEmpty);
    expect(lib.all.length, 1);
  });

  test('automatic pruning fires onClipDeleted (thumbnail cleanup path)',
      () async {
    final tmp = Directory.systemTemp.createTempSync('rewind_sm_hook');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final deleted = <String>[];
    final lib =
        ClipLibrary(clipsDir: tmp, onClipDeleted: (c) => deleted.add(c.path));
    final now = DateTime(2026, 1, 1, 12);
    lib.add(_clip('a', now.subtract(const Duration(hours: 3)), 10));
    lib.add(_clip('b', now.subtract(const Duration(hours: 1)), 10));

    final mgr =
        StorageManager(lib, policy: const RetentionPolicy(maxBytes: 15));
    await mgr.enforce(now: now);

    expect(deleted, contains('a'));
  });

  group('RetentionPolicy.fromSettings', () {
    test('maps GB to bytes and days to a Duration', () {
      final p = RetentionPolicy.fromSettings(
          AppSettings(maxStorageGb: 5, maxClipAgeDays: 30));
      expect(p.maxBytes, 5 * 1024 * 1024 * 1024);
      expect(p.maxAge, const Duration(days: 30));
    });

    test('nulls mean that cleanup axis is OFF', () {
      final p = RetentionPolicy.fromSettings(
          AppSettings(maxStorageGb: null, maxClipAgeDays: null));
      expect(p.maxBytes, isNull);
      expect(p.maxAge, isNull);
    });

    test('defaults reproduce the old hardcoded 20 GB cap, no age limit', () {
      final p = RetentionPolicy.fromSettings(AppSettings());
      expect(p.maxBytes, 20 * 1024 * 1024 * 1024);
      expect(p.maxAge, isNull);
    });
  });

  test('a policy swapped in at runtime is honored by the next enforce()',
      () async {
    // Settings change mid-session: main.dart writes storage.policy and
    // sweeps immediately — enforce must read the LIVE policy, not the one
    // it was constructed with.
    final tmp = Directory.systemTemp.createTempSync('rewind_sm_policy');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/old.mp4')..writeAsBytesSync(const [0]);
    final lib = ClipLibrary(clipsDir: tmp)
      ..add(_clip(f.path, DateTime(2026, 1, 1), 1));
    final mgr = StorageManager(lib); // default: 20 GB cap, no age limit
    expect(await mgr.enforce(now: DateTime(2026, 7, 1)), isEmpty);

    mgr.policy = const RetentionPolicy(maxAge: Duration(days: 30));
    final deleted = await mgr.enforce(now: DateTime(2026, 7, 1));
    expect(deleted, hasLength(1));
    expect(f.existsSync(), isFalse);
  });
}
