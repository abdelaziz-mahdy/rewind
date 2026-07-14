import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/widgets/game_tile_avatar.dart';

void main() {
  group('gameTileInitials', () {
    test('multi-word name takes the first letter of the first two words', () {
      expect(gameTileInitials('League of Legends'), 'LL');
      expect(gameTileInitials('Counter-Strike 2'), 'C2');
      expect(gameTileInitials('Grand Theft Auto V'), 'GT');
    });

    test('single-word name takes its first two letters', () {
      expect(gameTileInitials('VALORANT'), 'VA');
      expect(gameTileInitials('Fortnite'), 'FO');
    });

    test('single-letter word does not throw and returns what it has', () {
      expect(gameTileInitials('A'), 'A');
    });

    test('collapses extra whitespace before splitting into words', () {
      expect(gameTileInitials('  Rocket   League  '), 'RL');
    });

    test('empty name returns an empty string', () {
      expect(gameTileInitials(''), '');
      expect(gameTileInitials('   '), '');
    });
  });

  group('gameTileColor / gameTileTextColor', () {
    test('is deterministic: the same gameId always yields the same color', () {
      expect(gameTileColor('app:cs2'), gameTileColor('app:cs2'));
      expect(gameTileTextColor('app:cs2'), gameTileTextColor('app:cs2'));
    });

    test('different gameIds typically yield different hues', () {
      final ids = [
        'league_of_legends',
        'app:cs2',
        'app:dota2',
        'app:valorant',
        'app:fortnite',
        'desktop',
      ];
      final colors = ids.map(gameTileColor).toSet();
      // Not a strict guarantee for arbitrary strings, but for this set of
      // real gameIds the hues should spread out rather than collapse.
      expect(colors.length, greaterThan(1));
    });

    test('tile color is fixed at the spec\'s low saturation/lightness (§2)',
        () {
      final hsl = HSLColor.fromColor(gameTileColor('app:valorant'));
      expect(hsl.saturation, closeTo(0.25, 0.01));
      expect(hsl.lightness, closeTo(0.22, 0.01));
    });

    test('text color shares the tile\'s hue but is a lighter shade', () {
      final tileHsl = HSLColor.fromColor(gameTileColor('app:valorant'));
      final textHsl = HSLColor.fromColor(gameTileTextColor('app:valorant'));
      expect(textHsl.hue, closeTo(tileHsl.hue, 1.0));
      expect(textHsl.lightness, greaterThan(tileHsl.lightness));
    });
  });
}
