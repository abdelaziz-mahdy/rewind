import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/events/game_catalog.dart'
    show registerCustomDisplayNames;
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/all_clips_screen.dart';
import 'package:rewind/src/ui/match_clips_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart' show formatSize;
import 'package:rewind/src/ui/widgets/session_card.dart';

/// Records pushed routes so a session-card tap can be asserted by route
/// name without building MatchClipsScreen (whose ClipTiles need media_kit) —
/// same pattern as game_hub_screen_test.dart's identical helper.
class _RouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}

Widget _app(Widget child, {List<NavigatorObserver> observers = const []}) =>
    MaterialApp(
        theme: rewindTheme(),
        navigatorObservers: observers,
        home: Scaffold(body: child));

void main() {
  late Directory tmp;
  late ClipLibrary library;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_all_clips');
    library = ClipLibrary(clipsDir: tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Clip clip(String name, String gameId, GameEventKind event, DateTime createdAt,
          {int sizeBytes = 1024, DateTime? sessionAt}) =>
      Clip(
          path: '${tmp.path}/$name.mp4',
          gameId: gameId,
          event: event,
          createdAt: createdAt,
          sizeBytes: sizeBytes,
          sessionAt: sessionAt);

  AllClipsScreen screen({
    VoidCallback? onOpenClipsFolder,
    MatchStatsStore? matchStats,
  }) =>
      AllClipsScreen(
        library: library,
        hotkeyLabel: 'Alt+F10',
        onOpenClipsFolder: onOpenClipsFolder ?? () {},
        matchStats: matchStats,
      );

  // All Clips renders one SessionCard per play session — the same card a
  // game hub renders, so the two screens agree on what a session is.
  Finder sessionCard(String gameId, DateTime startedAt) => find
      .byKey(ValueKey('sessionCard:$gameId:${startedAt.toIso8601String()}'));

  Finder eventChip(String name) =>
      find.byKey(ValueKey('eventFilterChip:$name'));
  Finder countIn(Finder chipFinder, int count) =>
      find.descendant(of: chipFinder, matching: find.text('$count'));

  // The event-kind chip row and the clip list can show the same uppercase
  // badge text (e.g. a "PENTA KILL" chip label alongside a clip's "PENTA
  // KILL" badge) — scope badge/title assertions to the list itself so they
  // don't collide with the filter chips.
  Finder inList(Finder f) =>
      find.descendant(of: find.byKey(const ValueKey('clipsList')), matching: f);

  testWidgets('empty state shows the hotkey hint', (t) async {
    await t.pumpWidget(_app(screen()));
    expect(find.textContaining('Alt+F10'), findsOneWidget);
  });

  testWidgets('the empty-state "Open clips folder" button invokes the callback',
      (t) async {
    var opened = false;
    await t.pumpWidget(_app(screen(onOpenClipsFolder: () => opened = true)));
    await t.tap(find.widgetWithText(OutlinedButton, 'Open clips folder'));
    expect(opened, isTrue);
  });

  testWidgets('header shows clip count and total size', (t) async {
    library.add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1),
        sizeBytes: 2 * 1024 * 1024));
    library.add(clip('b', 'desktop', GameEventKind.manual, DateTime(2026, 7, 2),
        sizeBytes: 3 * 1024 * 1024));
    await t.pumpWidget(_app(screen()));

    expect(find.text('All clips'), findsOneWidget);
    expect(find.textContaining('2 clips · ${formatSize(5 * 1024 * 1024)}'),
        findsOneWidget);
  });

  testWidgets('the header folder button invokes onOpenClipsFolder', (t) async {
    var opened = false;
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    await t.pumpWidget(_app(screen(onOpenClipsFolder: () => opened = true)));
    await t.tap(find.widgetWithIcon(IconButton, Icons.folder_open_outlined));
    expect(opened, isTrue);
  });

  testWidgets('sessions render newest-first, each naming its game', (t) async {
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
        DateTime(2026, 7, 2)));
    await t.pumpWidget(_app(screen()));

    // The grid can place same-row cards side by side, so vertical position
    // no longer indicates order — newest-first is index order: the first
    // card GridView.builder constructs is the newest session.
    // GridView.builder's sliver keeps children in a SplayTreeMap keyed by
    // index, so `find`'s element-tree walk visits them in ascending index
    // order.
    final cards = t.widgetList<SessionCard>(find.byType(SessionCard)).toList();
    expect(cards, hasLength(2));
    expect(cards.first.displayName, 'League of Legends');
    expect(cards.last.displayName, 'Desktop');
  });

  testWidgets('library updates reactively when a clip is added', (t) async {
    await t.pumpWidget(_app(screen()));
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    await t.pump();
    expect(find.byType(SessionCard), findsOneWidget);
  });

  group('event-kind filter chips', () {
    testWidgets('one chip per distinct event kind, with counts', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(
          clip('b', 'desktop', GameEventKind.manual, DateTime(2026, 7, 2)));
      library.add(clip('c', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 3)));
      await t.pumpWidget(_app(screen()));

      expect(eventChip('all'), findsOneWidget);
      expect(countIn(eventChip('all'), 3), findsOneWidget);
      expect(eventChip('manual'), findsOneWidget);
      expect(countIn(eventChip('manual'), 2), findsOneWidget);
      expect(eventChip('pentaKill'), findsOneWidget);
      expect(countIn(eventChip('pentaKill'), 1), findsOneWidget);
    });

    testWidgets('selecting a chip filters the grid to sessions of that kind',
        (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(screen()));

      expect(find.byType(SessionCard), findsNWidgets(2));

      await t.tap(eventChip('pentaKill'));
      await t.pump();

      // The desktop session holds only a manual clip, so it drops out
      // entirely rather than rendering as an empty card.
      final cards = t.widgetList<SessionCard>(find.byType(SessionCard));
      expect(cards, hasLength(1));
      expect(cards.single.displayName, 'League of Legends');
    });

    testWidgets(
        'deleting the last clip of the filtered kind resets the filter to All',
        (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(screen()));

      await t.tap(eventChip('pentaKill'));
      await t.pump();
      expect(
          t
              .widgetList<SessionCard>(find.byType(SessionCard))
              .single
              .displayName,
          'League of Legends');

      // Synchronous remove() (not deleteClip(), which does real file I/O and
      // would hang the fake-async test zone) still fires the same
      // notifyListeners() the pruning logic reacts to.
      final pentaClip =
          library.all.firstWhere((c) => c.event == GameEventKind.pentaKill);
      library.remove(pentaClip);
      await t.pump();

      // Filter reset to All: the remaining desktop session is visible again.
      expect(
          t
              .widgetList<SessionCard>(find.byType(SessionCard))
              .single
              .displayName,
          'Desktop');
    });
  });

  group('session grouping (Task 17)', () {
    testWidgets('two sessions of the same game render two session cards',
        (t) async {
      final session1 = DateTime(2026, 7, 1, 10);
      final session2 = DateTime(2026, 7, 3, 20);
      library.add(clip('a', 'desktop', GameEventKind.manual,
          session1.add(const Duration(minutes: 5)),
          sessionAt: session1));
      library.add(clip('b', 'desktop', GameEventKind.manual,
          session2.add(const Duration(minutes: 5)),
          sessionAt: session2));
      await t.pumpWidget(_app(screen()));

      expect(sessionCard('desktop', session1), findsOneWidget);
      expect(sessionCard('desktop', session2), findsOneWidget);
    });

    testWidgets('sessions from different games interleave by recency',
        (t) async {
      final leagueOld = DateTime(2026, 7, 1, 10);
      final desktopMid = DateTime(2026, 7, 2, 10);
      final leagueNew = DateTime(2026, 7, 3, 10);
      library.add(clip('a', 'league_of_legends', GameEventKind.pentaKill,
          leagueOld.add(const Duration(minutes: 5)),
          sessionAt: leagueOld));
      library.add(clip('b', 'desktop', GameEventKind.manual,
          desktopMid.add(const Duration(minutes: 5)),
          sessionAt: desktopMid));
      library.add(clip('c', 'league_of_legends', GameEventKind.kill,
          leagueNew.add(const Duration(minutes: 5)),
          sessionAt: leagueNew));
      await t.pumpWidget(_app(screen()));

      // Newest-first across games — NOT game-partitioned: the desktop
      // session sits between League's two sessions, not after both. Grid
      // index order, not vertical position (cards share rows).
      final ids = t
          .widgetList<SessionCard>(find.byType(SessionCard))
          .map((c) => c.session.startedAt)
          .toList();
      expect(ids, [leagueNew, desktopMid, leagueOld]);
    });

    testWidgets("League's two gameIds sharing one stamp merge into ONE session",
        (t) async {
      final started = DateTime(2026, 7, 1, 10);
      library.add(clip('a', 'league_of_legends', GameEventKind.pentaKill,
          started.add(const Duration(minutes: 2)),
          sessionAt: started));
      // The newer clip of the pair carries the catalog id, so it becomes
      // the session's representative gameId (see `_sessionFeed`'s doc:
      // "its newest clip's").
      library.add(clip('b', 'app:league_of_legends', GameEventKind.manual,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      await t.pumpWidget(_app(screen()));

      expect(sessionCard('app:league_of_legends', started), findsOneWidget);
      expect(sessionCard('league_of_legends', started), findsNothing);
      expect(inList(find.textContaining('2 clips')), findsOneWidget);
    });

    testWidgets(
        'a renamed game\'s clips still bucket into ONE session under the '
        'renamed header (Task 28: rename must not fork the bucket)', (t) async {
      addTearDown(() => registerCustomDisplayNames({}));
      registerCustomDisplayNames({'app:cs2': 'CS2 ranked'});
      final started = DateTime(2026, 7, 1, 10);
      library.add(clip('a', 'app:cs2', GameEventKind.manual,
          started.add(const Duration(minutes: 2)),
          sessionAt: started));
      library.add(clip('b', 'app:cs2', GameEventKind.manual,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      await t.pumpWidget(_app(screen()));

      // Bucketed by the renamed display name, not the raw gameId — a
      // per-gameId card key still exists (both clips share one gameId here
      // regardless), but the visible label must be the override.
      expect(sessionCard('app:cs2', started), findsOneWidget);
      expect(find.textContaining('CS2 RANKED'), findsOneWidget);
      expect(find.textContaining('Counter-Strike'), findsNothing);
      expect(inList(find.textContaining('2 clips')), findsOneWidget);
    });

    testWidgets('tapping a session card navigates to the match screen',
        (t) async {
      final started = DateTime(2026, 7, 1, 10);
      library.add(clip('a', 'desktop', GameEventKind.manual,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      final observer = _RouteObserver();
      await t.pumpWidget(_app(screen(), observers: [observer]));
      observer.pushed.clear();

      await t.tap(sessionCard('desktop', started));
      // No further pump: the pushed route's builder (MatchClipsScreen →
      // ClipTile → media_kit) only runs next frame — assert the push
      // happened first, same pattern as game_hub_screen_test.dart.
      expect(observer.pushed.single.settings.name, matchClipsScreenRouteName);
    });

    testWidgets('a session with recorded stats reads as a MATCH', (t) async {
      final started = DateTime(2026, 7, 1, 10);
      final statsStore = MatchStatsStore(dir: tmp);
      statsStore.recordEvent(
          'league_of_legends', started, GameEventKind.kill, started);
      library.add(clip('a', 'league_of_legends', GameEventKind.kill,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      await t.pumpWidget(_app(screen(matchStats: statsStore)));

      final card = t.widget<SessionCard>(find.byType(SessionCard));
      expect(
          card.stats, same(statsStore.statsFor('league_of_legends', started)));
      // All Clips has no GameEntry to ask "does this game have a live-match
      // API", so recorded stats are the honest proxy.
      expect(card.isMatch, isTrue);
    });

    testWidgets('a session with no stats reads as a plain SESSION', (t) async {
      final started = DateTime(2026, 7, 1, 10);
      library.add(clip('a', 'desktop', GameEventKind.manual,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      await t.pumpWidget(_app(screen()));

      final card = t.widget<SessionCard>(find.byType(SessionCard));
      expect(card.stats, isNull);
      expect(card.isMatch, isFalse);
    });
  });

  group('sort', () {
    testWidgets('defaults to newest and can reorder by size', (t) async {
      final small = DateTime(2026, 7, 3, 10);
      final big = DateTime(2026, 7, 1, 10);
      library.add(clip('a', 'desktop', GameEventKind.manual,
          small.add(const Duration(minutes: 1)),
          sizeBytes: 1024, sessionAt: small));
      library.add(clip('b', 'desktop', GameEventKind.manual,
          big.add(const Duration(minutes: 1)),
          sizeBytes: 50 * 1024 * 1024, sessionAt: big));
      await t.pumpWidget(_app(screen()));

      List<DateTime> order() => t
          .widgetList<SessionCard>(find.byType(SessionCard))
          .map((c) => c.session.startedAt)
          .toList();
      expect(order(), [small, big]);

      await t.tap(find.byKey(const ValueKey('sortButton')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('Largest').last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      expect(order(), [big, small]);
    });
  });

  testWidgets('folder button sits flush right at wide widths', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    await t.pumpWidget(_app(screen()));
    final right = t.getTopRight(find.byTooltip('Open clips folder')).dx;
    // Flush with the header's right padding — a flex-allocation regression
    // once stranded it at ~60% of the row width.
    expect(right, greaterThan(1600 - 40));
  });
}
