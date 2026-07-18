import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/games/match_presentation.dart';
import 'package:rewind/src/ui/clip_sessions.dart';
import 'package:rewind/src/ui/match_clips_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart';

/// A presentation test double: returns exactly what each test configures, so
/// these tests can assert the SCREEN's frame/plumbing contract (what it does
/// with whatever a presentation returns) without depending on any real
/// per-game presentation — that behavior belongs to that presentation's own
/// test file (e.g. `test/games/league/league_match_presentation_test.dart`).
class _FakeMatchPresentation extends MatchPresentation {
  const _FakeMatchPresentation({this.summary, this.extras, this.footnoteText});

  final Widget? summary;
  final Widget? extras;
  final String? footnoteText;

  @override
  Widget? buildSummary(BuildContext context, MatchStats stats) => summary;

  @override
  Widget? buildExtras(BuildContext context, MatchStats stats) => extras;

  @override
  String? footnote(MatchStats? stats) => footnoteText;
}

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

  testWidgets('renders the app bar title and the clip grid', (t) async {
    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Ahri match',
      stats: null,
      library: library,
    )));
    await t.pump();

    expect(find.text('Ahri match'), findsOneWidget);
    expect(find.byKey(const ValueKey('matchClipsList')), findsOneWidget);
    expect(find.byType(ClipTile), findsNWidgets(session.clips.length));
  });

  testWidgets(
      'with no presentation, renders nothing extra above the grid — just '
      'the bare frame', (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
      champion: 'Ahri',
    );

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Ahri match',
      stats: stats,
      library: library,
    )));
    await t.pump();

    // No summary/footnote/extras entry was added above the grid.
    expect(find.byKey(const ValueKey('matchSummary')), findsNothing);
    expect(find.byKey(const ValueKey('matchFootnote')), findsNothing);
    expect(find.byKey(const ValueKey('matchExtras')), findsNothing);
  });

  testWidgets(
      'renders whatever a presentation returns: summary, footnote, extras',
      (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
    );
    const presentation = _FakeMatchPresentation(
      summary: Text('fake summary'),
      extras: Text('fake extras'),
      footnoteText: 'fake footnote',
    );

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Session',
      stats: stats,
      library: library,
      presentation: presentation,
    )));
    await t.pump();

    expect(find.text('fake summary'), findsOneWidget);
    expect(find.text('fake footnote'), findsOneWidget);
    expect(find.text('fake extras'), findsOneWidget);
  });

  testWidgets(
      'a presentation returning null for a piece renders nothing for that '
      'piece', (t) async {
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: session.startedAt,
    );
    const presentation = _FakeMatchPresentation(footnoteText: 'only this');

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Session',
      stats: stats,
      library: library,
      presentation: presentation,
    )));
    await t.pump();

    expect(find.text('only this'), findsOneWidget);
    // Summary/extras null: neither of their entries was added.
    expect(find.byKey(const ValueKey('matchSummary')), findsNothing);
    expect(find.byKey(const ValueKey('matchExtras')), findsNothing);
  });

  testWidgets(
      'the footnote call is handed the (possibly null) stats as-is — the '
      'screen does not gate on stats presence itself, the presentation does',
      (t) async {
    const presentation =
        _FakeMatchPresentation(footnoteText: 'renders even with no stats');

    await t.pumpWidget(app(MatchClipsScreen(
      session: session,
      matchLabel: 'Session',
      stats: null,
      library: library,
      presentation: presentation,
    )));
    await t.pump();

    expect(find.text('renders even with no stats'), findsOneWidget);
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
