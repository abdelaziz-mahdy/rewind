import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/games/game_descriptor.dart';
import 'package:rewind/src/games/league/league_match_presentation.dart';

void main() {
  group('descriptorFor', () {
    test('resolves League\'s merged descriptor from either of its two ids', () {
      final vendor = descriptorFor('league_of_legends');
      final catalog = descriptorFor('app:league_of_legends');

      expect(vendor.primaryGameId, 'league_of_legends');
      expect(
          vendor.mergedGameIds, {'league_of_legends', 'app:league_of_legends'});
      expect(vendor.hasLiveFeed, isTrue);
      expect(vendor.usesOfficialLogo, isFalse);
      // Both known ids resolve to the SAME descriptor, not two separate ones.
      expect(catalog.primaryGameId, vendor.primaryGameId);
      expect(catalog.mergedGameIds, vendor.mergedGameIds);
    });

    test('synthesizes a default descriptor for an arbitrary catalog id', () {
      final descriptor = descriptorFor('app:cs2');

      expect(descriptor.primaryGameId, 'app:cs2');
      expect(descriptor.mergedGameIds, {'app:cs2'});
      expect(descriptor.displayName, 'Counter-Strike 2');
      expect(descriptor.usesOfficialLogo, isTrue);
      expect(descriptor.hasLiveFeed, isFalse);
      expect(descriptor.eventGroups(), isEmpty);
      expect(descriptor.presentationFactory(), isNull);
    });

    test('synthesizes a default descriptor for a fully unrecognized id', () {
      final descriptor = descriptorFor('totally_custom_game');

      expect(descriptor.mergedGameIds, {'totally_custom_game'});
      expect(descriptor.displayName, 'Totally Custom Game');
      expect(descriptor.usesOfficialLogo, isTrue);
    });

    test('League\'s presentationFactory produces a LeagueMatchPresentation',
        () {
      expect(descriptorFor('league_of_legends').presentationFactory(),
          isA<LeagueMatchPresentation>());
    });
  });

  group(
      'usesOfficialLogo (descriptor field — polarity is TRUE = safe to '
      'show the real icon, opposite of ui/capture_app_match.dart\'s free '
      'function of the same name)', () {
    test('false for both of League\'s known gameIds', () {
      expect(descriptorFor('league_of_legends').usesOfficialLogo, isFalse);
      expect(descriptorFor('app:league_of_legends').usesOfficialLogo, isFalse);
    });

    test('false for Marvel Rivals (no fan-tool logo carve-out published)', () {
      expect(descriptorFor('app:marvel_rivals').usesOfficialLogo, isFalse);
    });

    test('true for a random catalog game', () {
      expect(descriptorFor('app:cs2').usesOfficialLogo, isTrue);
    });
  });
}
