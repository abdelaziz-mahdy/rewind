import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/clip_sessions.dart';
import 'package:rewind/src/ui/match_clips_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart';

void main() {
  late Directory tmp;
  late ClipLibrary library;
  late ClipSession session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_match_clips_screen');
    library = ClipLibrary(clipsDir: tmp);
    session = ClipSession(startedAt: DateTime.now(), clips: [
      Clip(
        path: '${tmp.path}/clip.mp4',
        gameId: 'league_of_legends',
        event: GameEventKind.kill,
        createdAt: DateTime.now(),
        sizeBytes: 1024,
      ),
    ]);
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  Widget app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

  testWidgets('the full stat line shows K/D/A, CS, and ward score', (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      champion: 'Ahri',
      gameMode: 'ARAM',
      kills: 5,
      deaths: 2,
      assists: 9,
      creepScore: 88,
      wardScore: 12.3,
    );

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Ahri match',
      stats: stats,
      library: library,
    )));
    await t.pump();

    expect(find.text('5 K · 2 D · 9 A · 88 CS · 12.3 WS'), findsOneWidget);
  });

  testWidgets('the skin name renders when known', (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      champion: 'Ahri',
      skinName: 'Spirit Blossom Ahri',
    );

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Ahri match',
      stats: stats,
      library: library,
    )));
    await t.pump();

    expect(find.text('Spirit Blossom Ahri'), findsOneWidget);
  });

  testWidgets('teammates/enemies show champion + in-game name together',
      (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      champion: 'Ahri',
      allies: const [MatchPlayer(championName: 'Lux', riotId: 'Mate#EUW')],
      enemies: const [MatchPlayer(championName: 'Zed', riotId: 'Foe#EUW')],
    );

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Ahri match',
      stats: stats,
      library: library,
    )));
    await t.pump();

    expect(find.text('Lux · Mate#EUW'), findsOneWidget);
    expect(find.text('Zed · Foe#EUW'), findsOneWidget);
  });

  testWidgets(
      'a teammate with no known name renders just the champion (no crash, '
      'no invented name)', (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      champion: 'Ahri',
      allies: const [MatchPlayer(championName: 'Lux')],
    );

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Ahri match',
      stats: stats,
      library: library,
    )));
    await t.pump();

    expect(find.text('Lux'), findsOneWidget);
    expect(find.textContaining('Lux ·'), findsNothing);
  });

  testWidgets('the item build renders one tile per item, no DDragon needed',
      (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      champion: 'Ahri',
      items: const [
        MatchItemSlot(itemId: 3157, slot: 0),
        MatchItemSlot(itemId: 3020, slot: 1),
      ],
    );

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Ahri match',
      stats: stats,
      library: library,
    )));
    await t.pump();

    // No DDragon wired up: both item tiles render as blank placeholders
    // (never a broken image), but still exist as two distinct containers.
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('no stats at all renders neither the info card nor a stat line',
      (t) async {
    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Session',
      stats: null,
      library: library,
    )));
    await t.pump();

    expect(find.textContaining(' K · '), findsNothing);
  });

  group('marker plumbing (Task 8)', () {
    // Asserted at the widget-contract level (what ClipTile was built with),
    // never by building PlayerScreen — see clip_tile.dart's/player_screen.
    // dart's doc on why PlayerScreen can't be built in a widget test.
    testWidgets('passes the match\'s events down to each ClipTile', (t) async {
      final events = [
        MatchEventStamp(kind: GameEventKind.kill, at: DateTime.now()),
        MatchEventStamp(kind: GameEventKind.dragonKill, at: DateTime.now()),
      ];
      final stats = MatchStats(
        gameId: 'league_of_legends',
        startedAt: session.startedAt,
        events: events,
      );

      await t.pumpWidget(app(MatchClipsScreen(
        session: session,
        matchLabel: 'Ahri match',
        stats: stats,
        library: library,
      )));
      await t.pump();

      expect(
        t.widget<ClipTile>(find.byType(ClipTile)).events,
        same(events),
      );
    });

    testWidgets(
        'no stats means ClipTile gets no events (plain seek bar, '
        'not an error)', (t) async {
      await t.pumpWidget(app(MatchClipsScreen(
        session: session,
        matchLabel: 'Session',
        stats: null,
        library: library,
      )));
      await t.pump();

      expect(t.widget<ClipTile>(find.byType(ClipTile)).events, isEmpty);
    });
  });
}
