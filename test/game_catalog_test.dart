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

    test(
        'the League client entry does not count as playing (it detects the '
        'client, not a live match)', () {
      final league = popularGamesCatalog
          .singleWhere((g) => g.gameId == 'app:league_of_legends');
      expect(league.countsAsPlaying, isFalse);
    });

    test('every other catalog entry counts as playing (default true)', () {
      for (final g in popularGamesCatalog) {
        if (g.gameId == 'app:league_of_legends') continue;
        expect(g.countsAsPlaying, isTrue,
            reason: '${g.gameId} should count as playing');
      }
    });
  });

  group('displayNameFor', () {
    test('resolves catalog ids to their display names', () {
      expect(displayNameFor('app:cs2'), 'Counter-Strike 2');
      expect(displayNameFor('app:league_of_legends'), 'League of Legends');
    });
    test('null and desktop resolve to Desktop', () {
      expect(displayNameFor(null), 'Desktop');
      expect(displayNameFor('desktop'), 'Desktop');
    });
    test('known vendor id resolves without the app: prefix', () {
      expect(displayNameFor('league_of_legends'), 'League of Legends');
    });
    test('unknown ids fall back to underscore title-casing', () {
      expect(displayNameFor('my_cool_game'), 'My Cool Game');
    });

    test(
        'registered custom names beat title-casing AND the catalog (Task '
        '28: a rename of a catalog game must win)', () {
      addTearDown(() => registerCustomDisplayNames({}));
      registerCustomDisplayNames({
        // A picked Wine app whose real casing the slug loses.
        'app:penguinhotel_win64_shipping': 'PenguinHotel-Win64-Shipping',
        // A user's explicit rename of a catalog game.
        'app:cs2': 'CS2 ranked',
      });
      expect(displayNameFor('app:penguinhotel_win64_shipping'),
          'PenguinHotel-Win64-Shipping');
      expect(displayNameFor('app:cs2'), 'CS2 ranked');
    });

    test(
        'a descriptor-registered game (League) ignores an override even if '
        'one is somehow registered — renaming it would desync its two '
        'merged gameIds\' names', () {
      addTearDown(() => registerCustomDisplayNames({}));
      registerCustomDisplayNames({
        'league_of_legends': 'Bogus Name',
        'app:league_of_legends': 'Also Bogus',
      });
      expect(displayNameFor('league_of_legends'), 'League of Legends');
      expect(displayNameFor('app:league_of_legends'), 'League of Legends');
    });

    test('an empty/whitespace override falls through to the derived name', () {
      addTearDown(() => registerCustomDisplayNames({}));
      registerCustomDisplayNames({
        'app:cs2': '',
        'my_cool_game': '   ',
      });
      expect(displayNameFor('app:cs2'), 'Counter-Strike 2');
      expect(displayNameFor('my_cool_game'), 'My Cool Game');
    });

    test('registerCustomDisplayNames replaces (not merges) the table', () {
      addTearDown(() => registerCustomDisplayNames({}));
      registerCustomDisplayNames({'app:gone_game': 'Gone Game!'});
      registerCustomDisplayNames({});
      expect(displayNameFor('app:gone_game'), 'App:gone Game');
    });
  });

  group('isGameRenameable / isDescriptorRegistered', () {
    test('false for both of League\'s merged gameIds', () {
      expect(isGameRenameable('league_of_legends'), isFalse);
      expect(isGameRenameable('app:league_of_legends'), isFalse);
      expect(isDescriptorRegistered('league_of_legends'), isTrue);
    });

    test('false for Marvel Rivals (also descriptor-registered)', () {
      expect(isGameRenameable('app:marvel_rivals'), isFalse);
    });

    test('true for a plain catalog game with no descriptor entry', () {
      expect(isGameRenameable('app:cs2'), isTrue);
      expect(isDescriptorRegistered('app:cs2'), isFalse);
    });

    test('true for a fully unrecognized id', () {
      expect(isGameRenameable('totally_custom_game'), isTrue);
    });
  });

  group('derivedDisplayNameFor', () {
    test('ignores any registered override', () {
      addTearDown(() => registerCustomDisplayNames({}));
      registerCustomDisplayNames({'app:cs2': 'CS2 ranked'});
      expect(derivedDisplayNameFor('app:cs2'), 'Counter-Strike 2');
    });

    test('resolves a descriptor-registered id to its descriptor name', () {
      expect(derivedDisplayNameFor('league_of_legends'), 'League of Legends');
    });

    test('falls back to title-casing for an unrecognized id', () {
      expect(derivedDisplayNameFor('my_cool_game'), 'My Cool Game');
    });
  });
}
