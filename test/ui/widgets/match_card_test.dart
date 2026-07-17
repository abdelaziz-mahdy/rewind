import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/clip_sessions.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/match_card.dart';

void main() {
  late Directory tmp;
  late ClipSession session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_match_card');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  Clip clip() => Clip(
        path: '${tmp.path}/clip.mp4',
        gameId: 'league_of_legends',
        event: GameEventKind.kill,
        createdAt: DateTime.now(),
        sizeBytes: 1024,
      );

  Widget app(Widget child) => MaterialApp(
        theme: rewindTheme(),
        home: Scaffold(body: SizedBox(width: 300, height: 400, child: child)),
      );

  setUp(() {
    session = ClipSession(startedAt: DateTime.now(), clips: [clip()]);
  });

  testWidgets('no stats: falls back to a plain clip count, no K/D/A row',
      (t) async {
    await t.pumpWidget(app(MatchCard(
      session: session,
      isMatch: true,
      stats: null,
      onTap: () {},
    )));
    await t.pump();

    expect(find.textContaining('K'), findsNothing);
    expect(find.text('1 clip'), findsOneWidget);
  });

  testWidgets('K/D/A + CS render when the match reports combat stats',
      (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      kills: 12,
      deaths: 3,
      assists: 7,
      creepScore: 145,
    );
    await t.pumpWidget(app(MatchCard(
      session: session,
      isMatch: true,
      stats: stats,
      onTap: () {},
    )));
    await t.pump();

    // "12" appears twice: the on-thumbnail badge AND the footer scoreboard.
    expect(find.text('12'), findsNWidgets(2));
    expect(find.text('145 CS'), findsOneWidget);
  });

  testWidgets(
      'a champion with no DDragon wired up falls back to the monogram, '
      'never a broken image', (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      champion: 'Ahri',
    );
    await t.pumpWidget(app(MatchCard(
      session: session,
      isMatch: true,
      stats: stats,
      onTap: () {},
      // ddragon deliberately omitted.
    )));
    await t.pump();

    expect(find.text('AH'), findsOneWidget); // gameTileInitials('Ahri')
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('tapping the card invokes onTap', (t) async {
    var tapped = false;
    await t.pumpWidget(app(MatchCard(
      session: session,
      isMatch: true,
      stats: null,
      onTap: () => tapped = true,
    )));
    await t.pump();

    await t.tap(find.byType(MatchCard));
    expect(tapped, isTrue);
  });
}
