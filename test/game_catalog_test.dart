import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_catalog.dart';

void main() {
  group('popularGamesCatalog', () {
    test('is non-empty', () {
      expect(popularGamesCatalog, isNotEmpty);
    });

    test('has no duplicate gameIds', () {
      final ids = popularGamesCatalog.map((g) => g.gameId).toList();
      expect(ids.toSet().length, ids.length,
          reason: 'duplicate gameId in catalog: $ids');
    });

    test('has no empty gameId, displayName, or processMatch', () {
      for (final g in popularGamesCatalog) {
        expect(g.gameId.trim(), isNotEmpty, reason: '$g has empty gameId');
        expect(g.displayName.trim(), isNotEmpty,
            reason: '$g has empty displayName');
        expect(g.processMatch.trim(), isNotEmpty,
            reason: '$g has empty processMatch');
      }
    });

    test(
        'gameIds are namespaced under app: so they never collide with a '
        'vendor-API watcher\'s gameId (e.g. league_of_legends)', () {
      for (final g in popularGamesCatalog) {
        expect(g.gameId, startsWith('app:'));
      }
    });

    // Simulates ProcessWatcherSource's case-insensitive substring match: a
    // catalog entry must not match common system/runtime process names, or
    // it would report a "game" active on every desktop.
    const systemProcesses = ['dart', 'sh', 'kernel', 'explorer', 'Finder'];

    test(
        'no catalog processMatch false-positives on common system '
        'processes', () {
      for (final g in popularGamesCatalog) {
        final needle = g.processMatch.toLowerCase();
        for (final sys in systemProcesses) {
          expect(sys.toLowerCase().contains(needle), isFalse,
              reason: '${g.gameId} processMatch "${g.processMatch}" would '
                  'match system process "$sys"');
        }
      }
    });
  });
}
