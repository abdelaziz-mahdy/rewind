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
import 'package:rewind/src/ui/widgets/clip_tile.dart' show ClipTile, formatSize;

/// Records pushed routes so a session-header tap can be asserted by route
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

  Finder sessionHeader(String gameId, DateTime startedAt) => find
      .byKey(ValueKey('sessionHeader:$gameId:${startedAt.toIso8601String()}'));

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
    await t.tap(find.widgetWithText(TextButton, 'Open clips folder'));
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

  testWidgets('clips render newest-first with event badge', (t) async {
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
        DateTime(2026, 7, 2)));
    await t.pumpWidget(_app(screen()));

    expect(inList(find.text('PENTA KILL')), findsOneWidget);
    expect(inList(find.text('MANUAL')), findsOneWidget);
    // The grid can place same-row cards side by side, so vertical position
    // no longer indicates order (unlike the old list) — newest-first is now
    // index order: the first ClipTile GridView.builder constructs is the
    // newest clip. GridView.builder's sliver keeps children in a
    // SplayTreeMap keyed by index, so `find`'s element-tree walk (and thus
    // `widgetList`) visits them in that same ascending index order.
    final tiles = t.widgetList<ClipTile>(find.byType(ClipTile)).toList();
    expect(tiles.first.clip.event, GameEventKind.pentaKill);
    expect(tiles.last.clip.event, GameEventKind.manual);
  });

  testWidgets('library updates reactively when a clip is added', (t) async {
    await t.pumpWidget(_app(screen()));
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    await t.pump();
    expect(find.text('MANUAL'), findsOneWidget);
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

    testWidgets('selecting a chip filters the list to that kind', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(screen()));

      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);

      await t.tap(eventChip('pentaKill'));
      await t.pump();

      expect(inList(find.text('MANUAL')), findsNothing);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
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
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
      expect(inList(find.text('MANUAL')), findsNothing);

      // Synchronous remove() (not deleteClip(), which does real file I/O and
      // would hang the fake-async test zone) still fires the same
      // notifyListeners() the pruning logic reacts to.
      final pentaClip =
          library.all.firstWhere((c) => c.event == GameEventKind.pentaKill);
      library.remove(pentaClip);
      await t.pump();

      // Filter reset to All: the remaining desktop clip is visible again.
      expect(inList(find.text('MANUAL')), findsOneWidget);
    });
  });

  group('session grouping (Task 17)', () {
    testWidgets('two sessions of the same game render two session headers',
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

      expect(sessionHeader('desktop', session1), findsOneWidget);
      expect(sessionHeader('desktop', session2), findsOneWidget);
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
      // session sits between League's two sessions, not after both.
      final yNew =
          t.getTopLeft(sessionHeader('league_of_legends', leagueNew)).dy;
      final yMid = t.getTopLeft(sessionHeader('desktop', desktopMid)).dy;
      final yOld =
          t.getTopLeft(sessionHeader('league_of_legends', leagueOld)).dy;
      expect(yNew, lessThan(yMid));
      expect(yMid, lessThan(yOld));
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

      expect(sessionHeader('app:league_of_legends', started), findsOneWidget);
      expect(sessionHeader('league_of_legends', started), findsNothing);
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
      // per-gameId header key still exists (both clips share one gameId
      // here regardless), but the visible label must be the override.
      expect(sessionHeader('app:cs2', started), findsOneWidget);
      expect(find.text('CS2 RANKED'), findsOneWidget);
      expect(find.textContaining('Counter-Strike'), findsNothing);
      expect(inList(find.textContaining('2 clips')), findsOneWidget);
    });

    testWidgets('tapping a session header navigates to the match screen',
        (t) async {
      final started = DateTime(2026, 7, 1, 10);
      library.add(clip('a', 'desktop', GameEventKind.manual,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      final observer = _RouteObserver();
      await t.pumpWidget(_app(screen(), observers: [observer]));
      observer.pushed.clear();

      await t.tap(sessionHeader('desktop', started));
      // No further pump: the pushed route's builder (MatchClipsScreen →
      // ClipTile → media_kit) only runs next frame — assert the push
      // happened first, same pattern as game_hub_screen_test.dart.
      expect(observer.pushed.single.settings.name, matchClipsScreenRouteName);
    });

    testWidgets(
        "a clip tile in a session with stats receives the stats' events",
        (t) async {
      final started = DateTime(2026, 7, 1, 10);
      final statsStore = MatchStatsStore(dir: tmp);
      statsStore.recordEvent(
          'league_of_legends', started, GameEventKind.kill, started);
      library.add(clip('a', 'league_of_legends', GameEventKind.kill,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      await t.pumpWidget(_app(screen(matchStats: statsStore)));

      final stats = statsStore.statsFor('league_of_legends', started)!;
      expect(stats.events, isNotEmpty);
      expect(
        t.widget<ClipTile>(find.byType(ClipTile)).events,
        same(stats.events),
      );
    });

    testWidgets('a session with no stats gives its clip tiles no events',
        (t) async {
      final started = DateTime(2026, 7, 1, 10);
      library.add(clip('a', 'desktop', GameEventKind.manual,
          started.add(const Duration(minutes: 5)),
          sessionAt: started));
      await t.pumpWidget(_app(screen()));

      expect(t.widget<ClipTile>(find.byType(ClipTile)).events, isEmpty);
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
