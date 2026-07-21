import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/icns.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/game_tile_avatar.dart';

/// A real, fully-decodable 1×1 transparent PNG (the smallest valid PNG with
/// an actual IDAT chunk) — `Image.memory` needs a real decode, unlike
/// `test/ui/icns_test.dart`'s magic-bytes-only fixture, which has no IDAT
/// and fails Flutter's image codec.
final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVR42mNk+A8A'
    'AQUBAScY42YAAAAASUVORK5CYII=');

/// A minimal valid `.icns` file holding one PNG-encoded `icp5` chunk.
Uint8List _fakeIcns() {
  final body = <int>[
    ...'icp5'.codeUnits,
    ..._lenBytes(_tinyPng.length + 8),
    ..._tinyPng,
  ];
  final total = body.length + 8;
  return Uint8List.fromList(
      [..."icns".codeUnits, ..._lenBytes(total), ...body]);
}

List<int> _lenBytes(int len) =>
    [len >> 24 & 0xFF, len >> 16 & 0xFF, len >> 8 & 0xFF, len & 0xFF];

void main() {
  group('GameTileAvatar real icon rendering', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rewind_game_tile_avatar');
      clearAppIconCache();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Widget app(Widget child) =>
        MaterialApp(theme: rewindTheme(), home: Scaffold(body: child));

    testWidgets('a valid iconPath renders the real icon, not the monogram',
        (t) async {
      final iconFile = File('${tmp.path}/App.icns')
        ..writeAsBytesSync(_fakeIcns());

      await t.pumpWidget(app(GameTileAvatar(
        gameId: 'app:cs2',
        displayName: 'Counter-Strike 2',
        iconPath: iconFile.path,
        size: 28,
      )));

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('C2'), findsNothing);
    });

    testWidgets('a null iconPath falls back to the monogram', (t) async {
      await t.pumpWidget(app(const GameTileAvatar(
        gameId: 'app:cs2',
        displayName: 'Counter-Strike 2',
        size: 28,
      )));

      expect(find.byType(Image), findsNothing);
      expect(find.text('C2'), findsOneWidget);
    });

    testWidgets(
        'an iconPath pointing at a missing/unreadable file falls back to '
        'the monogram, never a broken image', (t) async {
      await t.pumpWidget(app(GameTileAvatar(
        gameId: 'app:cs2',
        displayName: 'Counter-Strike 2',
        iconPath: '${tmp.path}/does-not-exist.icns',
        size: 28,
      )));

      expect(find.byType(Image), findsNothing);
      expect(find.text('C2'), findsOneWidget);
    });

    testWidgets(
        'a jpg/png iconPath (Steam library art) renders off disk, not the '
        'monogram', (t) async {
      final iconFile = File('${tmp.path}/steam-3241660.png')
        ..writeAsBytesSync(_tinyPng);

      await t.pumpWidget(app(GameTileAvatar(
        gameId: 'app:repo',
        displayName: 'Repo',
        iconPath: iconFile.path,
        size: 32,
      )));

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('RE'), findsNothing);
    });

    testWidgets('a missing jpg/png iconPath falls back to the monogram',
        (t) async {
      await t.pumpWidget(app(GameTileAvatar(
        gameId: 'app:repo',
        displayName: 'Repo',
        iconPath: '${tmp.path}/steam-nope.jpg',
        size: 32,
      )));

      expect(find.byType(Image), findsNothing);
      expect(find.text('RE'), findsOneWidget);
    });

    testWidgets(
        'a Wine game (no iconPath, per AppInfo.iconPath\'s contract) always '
        'shows the monogram', (t) async {
      await t.pumpWidget(app(const GameTileAvatar(
        gameId: 'app:penguinhotel',
        displayName: 'PenguinHotel-Win64-Shipping',
        iconPath: null,
        size: 28,
      )));

      expect(find.byType(Image), findsNothing);
    });

    testWidgets('desktop keeps its monitor icon even with no iconPath',
        (t) async {
      await t.pumpWidget(app(const GameTileAvatar(
        gameId: 'desktop',
        displayName: 'Desktop',
        size: 28,
      )));

      expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);
    });
  });

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
