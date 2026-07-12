import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/events/game_event.dart';

Clip _clip(String path, DateTime at, int bytes, {bool protected = false}) => Clip(
      path: path,
      gameId: 'test',
      event: GameEventKind.kill,
      createdAt: at,
      sizeBytes: bytes,
      protected: protected,
    );

void main() {
  test('budget pruning deletes oldest unprotected first, keeps protected', () async {
    final lib = ClipLibrary();
    final now = DateTime(2026, 1, 1, 12);
    // 3 clips of 10 bytes each = 30; budget 15 -> must drop to <=15.
    lib.add(_clip('a', now.subtract(const Duration(hours: 3)), 10)); // oldest
    lib.add(_clip('b', now.subtract(const Duration(hours: 2)), 10, protected: true));
    lib.add(_clip('c', now.subtract(const Duration(hours: 1)), 10)); // newest

    final mgr = StorageManager(lib, policy: const RetentionPolicy(maxBytes: 15));
    final deleted = await mgr.enforce(now: now);

    // 'a' (oldest, unprotected) deleted; 'b' protected must survive.
    expect(deleted.map((c) => c.path), contains('a'));
    expect(lib.all.any((c) => c.path == 'b'), isTrue);
  });

  test('protected clips are never removed by age policy', () async {
    final lib = ClipLibrary();
    final now = DateTime(2026, 1, 1, 12);
    lib.add(_clip('old', now.subtract(const Duration(days: 30)), 10, protected: true));

    final mgr = StorageManager(lib, policy: const RetentionPolicy(maxAge: Duration(days: 7)));
    final deleted = await mgr.enforce(now: now);

    expect(deleted, isEmpty);
    expect(lib.all.length, 1);
  });
}
