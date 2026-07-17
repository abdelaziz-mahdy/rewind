import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/games/league/game_modes.dart';

void main() {
  group('friendlyLeagueGameMode', () {
    test('maps raw codes we know', () {
      expect(friendlyLeagueGameMode('CLASSIC'), "Summoner's Rift");
      expect(friendlyLeagueGameMode('CHERRY'), 'Arena');
      expect(friendlyLeagueGameMode('ARAM'), 'ARAM');
      // Verified against a live match 2026-07-16.
      expect(friendlyLeagueGameMode('KIWI'), 'ARAM Mayhem');
    });

    test(
        'HEALS matches recorded before a mode was mapped — the reason this '
        'resolves at render instead of at capture', () {
      // A build that didn't know KIWI persisted its title-cased fallback
      // ("Kiwi") into matches.json, where it was frozen: mapping at capture
      // time meant the fix could never reach matches already recorded. Those
      // rows now come back through here and render correctly.
      expect(friendlyLeagueGameMode('Kiwi'), 'ARAM Mayhem');
    });

    test('leaves already-friendly stored values alone', () {
      // Old rows persisted the friendly name, not the code — "Arena" must not
      // be mangled (its raw code is CHERRY, so it matches no code entry).
      expect(friendlyLeagueGameMode('Arena'), 'Arena');
      expect(friendlyLeagueGameMode("Summoner's Rift"), "Summoner's Rift");
      expect(friendlyLeagueGameMode('Nexus Blitz'), 'Nexus Blitz');
    });

    test('an unmapped code title-cases at RENDER, so it is never frozen', () {
      // Riot ships modes faster than we map them. The fallback must happen
      // here — never in storage — so adding the mode later fixes old matches.
      expect(friendlyLeagueGameMode('SOMENEWMODE'), 'Somenewmode');
    });

    test('null/blank stay null', () {
      expect(friendlyLeagueGameMode(null), isNull);
      expect(friendlyLeagueGameMode(''), isNull);
      expect(friendlyLeagueGameMode('   '), isNull);
    });
  });

  group('isTwoTeamLeagueMode', () {
    test('real 2-team modes', () {
      expect(isTwoTeamLeagueMode('CLASSIC'), isTrue);
      expect(isTwoTeamLeagueMode('ARAM'), isTrue);
      expect(isTwoTeamLeagueMode('KIWI'), isTrue); // ARAM Mayhem is 5v5
    });

    test('Arena is NOT — its team field is arbitrary (verified live)', () {
      // 12 ORDER / 6 CHAOS in an 18-player game: not the duos. Splitting on it
      // would invent teammates.
      expect(isTwoTeamLeagueMode('CHERRY'), isFalse);
    });

    test('unknown modes are not assumed to be 2-team', () {
      expect(isTwoTeamLeagueMode('SOMENEWMODE'), isFalse);
      expect(isTwoTeamLeagueMode(null), isFalse);
    });
  });
}
