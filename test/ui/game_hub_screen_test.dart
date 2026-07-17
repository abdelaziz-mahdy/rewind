import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/game_hub_screen.dart';
import 'package:rewind/src/ui/match_clips_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart' show formatSize;
import 'package:rewind/src/ui/widgets/match_card.dart';
import '../fakes/fake_capture_engine.dart';
import '../fakes/fake_game_source.dart';

/// Records pushed routes so a match-card tap can be asserted by route name
/// without building MatchClipsScreen (whose ClipTiles need media_kit).
class _RouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}

Widget _app(Widget child) =>
    MaterialApp(theme: rewindTheme(), home: Scaffold(body: child));

/// The hub's content is a single scrollable page (header with a folded-in
/// status detail line, an optional live-events card, the collapsed-by-
/// default "Capture settings" disclosure, then the clip list) — League's
/// version, with the disclosure expanded and its auto-clip switch/event
/// matrix showing, is tall enough that the default test viewport leaves the
/// clip list and lower matrix groups outside the sliver's build extent (a
/// lazily-built list never realizes off-screen children, test or not).
/// Widening the test surface, rather than scrolling per-assertion, keeps
/// every test able to just `find` what it needs.
Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1200, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(child);
}

void main() {
  late Directory tmp;
  late ClipLibrary library;
  late ClipCoordinator coordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_game_hub');
    library = ClipLibrary(clipsDir: tmp);
    coordinator = ClipCoordinator(
      registry: GameRegistry(sources: []),
      library: library,
      storage: StorageManager(library),
      settings: AppSettings(),
      outDir: tmp.path,
      engine: FakeCaptureEngine(),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Clip clip(String path, String gameId, GameEventKind event, DateTime createdAt,
          {int sizeBytes = 1024}) =>
      Clip(
          path: '${tmp.path}/$path.mp4',
          gameId: gameId,
          event: event,
          createdAt: createdAt,
          sizeBytes: sizeBytes);

  GameHubScreen hub({
    required String gameId,
    ClipCoordinator? coordinatorOverride,
    Future<void> Function(AppSettings)? onSettingsChanged,
  }) =>
      GameHubScreen(
        gameId: gameId,
        library: library,
        coordinator: coordinatorOverride ?? coordinator,
        hotkeyLabel: 'Alt+F10',
        onSettingsChanged: onSettingsChanged ?? (_) async {},
      );

  Finder inList(Finder f) =>
      find.descendant(of: find.byKey(const ValueKey('clipsList')), matching: f);

  Finder inLiveEvents(Finder f) => find.descendant(
      of: find.byKey(const ValueKey('liveEventsSlot')), matching: f);

  Finder detailLine() => find.byKey(const ValueKey('gameHubDetailLine'));
  Finder settingsToggle() =>
      find.byKey(const ValueKey('captureSettingsToggle'));

  Future<void> expandSettings(WidgetTester t) async {
    await t.tap(settingsToggle());
    await t.pumpAndSettle();
  }

  group('session grouping', () {
    testWidgets(
        'clips with distinct sessionAt stamps render under separate MATCH '
        'headers for a Live-Client-API game', (t) async {
      final match1 = DateTime(2026, 7, 14, 20);
      final match2 = DateTime(2026, 7, 14, 22);
      library.add(Clip(
          path: '${tmp.path}/a.mp4',
          gameId: 'league_of_legends',
          event: GameEventKind.kill,
          createdAt: DateTime(2026, 7, 14, 20, 10),
          sizeBytes: 1,
          sessionAt: match1));
      library.add(Clip(
          path: '${tmp.path}/b.mp4',
          gameId: 'league_of_legends',
          event: GameEventKind.kill,
          createdAt: DateTime(2026, 7, 14, 20, 25),
          sizeBytes: 1,
          sessionAt: match1));
      library.add(Clip(
          path: '${tmp.path}/c.mp4',
          gameId: 'league_of_legends',
          event: GameEventKind.ace,
          createdAt: DateTime(2026, 7, 14, 22, 5),
          sizeBytes: 1,
          sessionAt: match2));
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      // Each session is one MATCH card, labeled "MATCH · <age>", with a
      // clip count in its summary line.
      final headers = inList(find.textContaining('MATCH · '));
      expect(headers, findsNWidgets(2));
      expect(inList(find.text('2 clips')), findsOneWidget);
      expect(inList(find.text('1 clip')), findsOneWidget);
    });

    testWidgets('a process-detected game labels its groups SESSION, not MATCH',
        (t) async {
      library.add(
          clip('a', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 1)));
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(inList(find.textContaining('SESSION · ')), findsOneWidget);
      expect(inList(find.textContaining('MATCH · ')), findsNothing);
    });
  });

  group('header stats', () {
    testWidgets('omits the fact row when the game has no clips', (t) async {
      await _pump(t, _app(hub(gameId: 'app:cs2')));
      expect(find.textContaining('clips ·'), findsNothing);
    });

    testWidgets('shows clip count, total size, and last-clip age', (t) async {
      library.add(clip(
          'a', 'app:cs2', GameEventKind.manual, DateTime(2026, 1, 1),
          sizeBytes: 2 * 1024 * 1024));
      library.add(clip(
          'b', 'app:cs2', GameEventKind.manual, DateTime(2026, 1, 2),
          sizeBytes: 3 * 1024 * 1024));
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(find.textContaining('2 clips · ${formatSize(5 * 1024 * 1024)}'),
          findsOneWidget);
      expect(find.textContaining('last clip'), findsOneWidget);
    });
  });

  group('header detail line (folded in from the old integration-status card)',
      () {
    testWidgets(
        'League merged row: only the CLIENT open (process half active) must '
        'NOT read as in-match — the API is not even listening', (t) async {
      // Regression: sitting in the lobby (LeagueClientUx running, catalog
      // half active) used to show "In match — connected to 127.0.0.1:2999"
      // while nothing was listening on 2999 at all.
      coordinator.settings.setConfig(GameConfig(gameId: 'league_of_legends'));
      coordinator.activeGameIds.value = {'app:league_of_legends'};
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(find.text('LIVE CLIENT API'), findsOneWidget); // the header pill
      expect(
          t.widget<Text>(detailLine()).data,
          'Client open — waiting for a match. Rewind connects automatically '
          'when one starts.');
    });

    testWidgets(
        'League merged row: the vendor-API half active means an actual '
        'match', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'league_of_legends'));
      coordinator.activeGameIds.value = {'league_of_legends'};
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(t.widget<Text>(detailLine()).data,
          'In match — connected to 127.0.0.1:2999');
    });

    testWidgets('League shows the waiting state when inactive', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'league_of_legends'));
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(
          t.widget<Text>(detailLine()).data,
          'Waiting for a match. Detection is automatic — start a game and '
          'Rewind connects.');
    });

    testWidgets('catalog game shows its processMatch when inactive', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(find.text('PROCESS DETECTION'), findsOneWidget);
      expect(t.widget<Text>(detailLine()).data, 'Watching for cs2');
    });

    testWidgets('catalog game shows "Running now" while active', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
      coordinator.activeGameIds.value = {'app:cs2'};
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(t.widget<Text>(detailLine()).data, 'Running now');
    });

    testWidgets('desktop shows manual capture with the hotkey hint', (t) async {
      await _pump(t, _app(hub(gameId: 'desktop')));

      expect(find.text('MANUAL CAPTURE'), findsOneWidget); // the header pill
      expect(t.widget<Text>(detailLine()).data,
          'Clips saved with Alt+F10 while no game is detected.');
    });

    testWidgets('the old standalone integration card is gone', (t) async {
      await _pump(t, _app(hub(gameId: 'desktop')));
      expect(find.byKey(const ValueKey('integrationCard')), findsNothing);
    });
  });

  group('capture settings disclosure', () {
    testWidgets(
        'collapsed by default: buffer/auto-clip/matrix controls are not '
        'found until the disclosure is expanded', (t) async {
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(find.text('Buffer length'), findsNothing);
      expect(find.byKey(const ValueKey('gameHubAutoClipSwitch')), findsNothing);
      expect(find.byKey(const ValueKey('gameHubEventMatrix')), findsNothing);

      await expandSettings(t);

      expect(find.text('Buffer length'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('gameHubAutoClipSwitch')), findsOneWidget);
      expect(find.byKey(const ValueKey('gameHubEventMatrix')), findsOneWidget);
    });

    testWidgets('a per-game buffer edit fires onSettingsChanged', (t) async {
      final calls = <AppSettings>[];
      await _pump(
          t,
          _app(hub(
            gameId: 'app:cs2',
            onSettingsChanged: (s) async => calls.add(s),
          )));
      await expandSettings(t);

      await t.tap(find.text('60 s'));
      await t.pump();

      expect(calls, isNotEmpty);
      expect(coordinator.settings.configFor('app:cs2').bufferSeconds, 60);
    });

    testWidgets('the event matrix and auto-clip switch appear only for League',
        (t) async {
      await _pump(t, _app(hub(gameId: 'league_of_legends')));
      await expandSettings(t);

      expect(
          find.byKey(const ValueKey('gameHubAutoClipSwitch')), findsOneWidget);
      expect(find.byKey(const ValueKey('gameHubEventMatrix')), findsOneWidget);
      expect(find.text('COMBAT'), findsOneWidget);
      expect(find.text('OBJECTIVES'), findsOneWidget);
      expect(find.text('MATCH'), findsOneWidget);
      // `manual` is never part of the auto-clip matrix (the hotkey always
      // saves regardless of this config).
      expect(find.byKey(const ValueKey('eventToggle:manual')), findsNothing);
    });

    testWidgets('no event matrix or auto-clip switch for catalog/desktop games',
        (t) async {
      await _pump(t, _app(hub(gameId: 'app:cs2')));
      await expandSettings(t);
      expect(find.byKey(const ValueKey('gameHubAutoClipSwitch')), findsNothing);
      expect(find.byKey(const ValueKey('gameHubEventMatrix')), findsNothing);

      await _pump(t, _app(hub(gameId: 'desktop')));
      await expandSettings(t);
      expect(find.byKey(const ValueKey('gameHubAutoClipSwitch')), findsNothing);
      expect(find.byKey(const ValueKey('gameHubEventMatrix')), findsNothing);
    });

    testWidgets('toggling an event in the matrix updates enabledEvents',
        (t) async {
      final calls = <AppSettings>[];
      await _pump(
          t,
          _app(hub(
            gameId: 'league_of_legends',
            onSettingsChanged: (s) async => calls.add(s),
          )));
      await expandSettings(t);

      // `ace` is enabled by GameConfig's own defaults; toggle it off.
      await t.tap(find.byKey(const ValueKey('eventToggle:ace')));
      await t.pump();

      expect(calls, isNotEmpty);
      expect(coordinator.settings.configFor('league_of_legends').enabledEvents,
          isNot(contains(GameEventKind.ace)));

      // `dragonKill` is not enabled by default; toggle it on.
      await t.tap(find.byKey(const ValueKey('eventToggle:dragonKill')));
      await t.pump();
      expect(coordinator.settings.configFor('league_of_legends').enabledEvents,
          contains(GameEventKind.dragonKill));
    });
  });

  group('match grid', () {
    testWidgets('scopes to this game only (one card, one clip)', (t) async {
      library.add(
          clip('a', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      // Only the cs2 session shows — one card, and it holds only cs2's clip.
      expect(find.byType(MatchCard), findsOneWidget);
      expect(inList(find.text('1 clip')), findsOneWidget);
    });

    testWidgets(
        'League\'s hub merges the vendor + catalog gameIds into one session',
        (t) async {
      // Two clips minutes apart (same gap-cluster) under the two League
      // gameIds — if the merge dropped the catalog clip, the card would say
      // "1 clip".
      library.add(clip('a', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2, 20, 0)));
      library.add(clip('b', 'app:league_of_legends', GameEventKind.manual,
          DateTime(2026, 7, 2, 20, 5)));
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(find.byType(MatchCard), findsOneWidget);
      expect(inList(find.text('2 clips')), findsOneWidget);
    });

    testWidgets(
        'a match card shows its K/D scoreboard and tapping opens the match',
        (t) async {
      final stamp = DateTime(2026, 7, 14, 20);
      final statsStore = MatchStatsStore(dir: tmp);
      statsStore.recordKill('league_of_legends', stamp);
      statsStore.recordKill('league_of_legends', stamp);
      statsStore.recordKill('league_of_legends', stamp);
      statsStore.recordDeath('league_of_legends', stamp);
      final leagueCoordinator = ClipCoordinator(
        registry: GameRegistry(sources: []),
        library: library,
        storage: StorageManager(library),
        settings: AppSettings(),
        outDir: tmp.path,
        engine: FakeCaptureEngine(),
        matchStats: statsStore,
      )..start(supervise: false);

      library.add(Clip(
          path: '${tmp.path}/a.mp4',
          gameId: 'league_of_legends',
          event: GameEventKind.pentaKill,
          createdAt: DateTime(2026, 7, 14, 20, 8),
          sizeBytes: 1,
          sessionAt: stamp));

      final observer = _RouteObserver();
      await _pump(
          t,
          MaterialApp(
            theme: rewindTheme(),
            navigatorObservers: [observer],
            home: Scaffold(
                body: hub(
                    gameId: 'league_of_legends',
                    coordinatorOverride: leagueCoordinator)),
          ));

      // K/D scoreboard: 3 K, 1 D. The footer's " K"/" D" labels are unique;
      // the "3"/"1" numbers appear in both the thumbnail badge and the
      // footer, so they render at least once.
      expect(inList(find.text(' K')), findsOneWidget);
      expect(inList(find.text(' D')), findsOneWidget);
      expect(inList(find.text('3')), findsWidgets);
      expect(inList(find.text('1')), findsWidgets);

      observer.pushed.clear();
      await t.tap(find.byType(MatchCard));
      // No pump: the pushed route's builder (MatchClipsScreen → ClipTile →
      // media_kit) only runs next frame; assert the push happened first.
      expect(observer.pushed.single.settings.name, matchClipsScreenRouteName);
    });

    testWidgets('empty scope shows the game-specific empty state', (t) async {
      await _pump(t, _app(hub(gameId: 'app:cs2')));
      expect(
          find.text('No Counter-Strike 2 clips yet — press Alt+F10 during '
              'a game.'),
          findsOneWidget);
    });
  });

  group('live-events feed slot (v0.2 seam)', () {
    testWidgets('hidden while no event for this game has arrived this session',
        (t) async {
      await _pump(t, _app(hub(gameId: 'league_of_legends')));
      expect(find.byKey(const ValueKey('liveEventsSlot')), findsNothing);
    });

    testWidgets('appears once a GameEvent for this gameId is emitted',
        (t) async {
      final fakeSource =
          FakeGameSource('league_of_legends', 'League of Legends');
      final registry = GameRegistry(sources: [fakeSource]);
      final leagueCoordinator = ClipCoordinator(
        registry: registry,
        library: library,
        storage: StorageManager(library),
        settings: AppSettings(),
        outDir: tmp.path,
        engine: FakeCaptureEngine(),
      )..start(supervise: false);

      await _pump(
          t,
          _app(hub(
            gameId: 'league_of_legends',
            coordinatorOverride: leagueCoordinator,
          )));
      expect(find.byKey(const ValueKey('liveEventsSlot')), findsNothing);

      fakeSource.running = true;
      await registry.tickNow();
      fakeSource.emit(GameEventKind.kill);
      await t.pump();

      expect(find.byKey(const ValueKey('liveEventsSlot')), findsOneWidget);
      expect(inLiveEvents(find.text('KILL')), findsOneWidget);

      // The emitted kill started a burst-debounce timer in the coordinator;
      // cancel it inside the test body — the binding's pending-timer
      // invariant runs before addTearDown callbacks would.
      leagueCoordinator.dispose();
    });

    testWidgets('never appears for non-League games (no vendor event source)',
        (t) async {
      await _pump(t, _app(hub(gameId: 'app:cs2')));
      expect(find.byKey(const ValueKey('liveEventsSlot')), findsNothing);
    });
  });

  group('event toggle chips', () {
    /// The chip's label colour, by event kind.
    Color labelColor(WidgetTester t, GameEventKind kind) => t
        .widget<Text>(find.descendant(
          of: find.byKey(ValueKey('eventToggle:${kind.name}')),
          matching: find.byType(Text),
        ))
        .style!
        .color!;

    testWidgets(
        'an ENABLED event is more prominent than a disabled one — the state '
        'used to be inverted', (t) async {
      // Regression: unselected chips drew full-brightness `tokens.text` while
      // selected ones drew the dimmer accent, so a hub's loudest elements
      // were the events the player had switched OFF (KILL enabled read as a
      // whisper next to DRAGON KILL disabled shouting in white).
      final settings = AppSettings()
        ..setConfig(GameConfig(
          gameId: 'league_of_legends',
          enabledEvents: {GameEventKind.kill},
        ));
      await _pump(
          t,
          _app(GameHubScreen(
            gameId: 'league_of_legends',
            library: library,
            coordinator: ClipCoordinator(
              registry: GameRegistry(sources: []),
              library: library,
              storage: StorageManager(library),
              settings: settings,
              outDir: tmp.path,
              engine: FakeCaptureEngine(),
            ),
            hotkeyLabel: 'Alt+F10',
            onSettingsChanged: (_) async {},
          )));
      await expandSettings(t);

      final on = labelColor(t, GameEventKind.kill);
      final off = labelColor(t, GameEventKind.dragonKill);
      expect(on, isNot(off));
      // The real assertion: ON must not be dimmer than OFF.
      expect(on.computeLuminance(), greaterThan(off.computeLuminance()),
          reason: 'an enabled event must not read dimmer than a disabled one');
    });

    testWidgets('state is not signalled by colour alone — ON carries a check',
        (t) async {
      // ~14 same-size, same-shape chips distinguished only by hue is nothing
      // to a colour-blind player, so "on" also shows a check glyph.
      final settings = AppSettings()
        ..setConfig(GameConfig(
          gameId: 'league_of_legends',
          enabledEvents: {GameEventKind.kill},
        ));
      await _pump(
          t,
          _app(GameHubScreen(
            gameId: 'league_of_legends',
            library: library,
            coordinator: ClipCoordinator(
              registry: GameRegistry(sources: []),
              library: library,
              storage: StorageManager(library),
              settings: settings,
              outDir: tmp.path,
              engine: FakeCaptureEngine(),
            ),
            hotkeyLabel: 'Alt+F10',
            onSettingsChanged: (_) async {},
          )));
      await expandSettings(t);

      Finder checkIn(GameEventKind k) => find.descendant(
            of: find.byKey(ValueKey('eventToggle:${k.name}')),
            matching: find.byIcon(Icons.check),
          );
      expect(checkIn(GameEventKind.kill), findsOneWidget);
      expect(checkIn(GameEventKind.dragonKill), findsNothing);
    });
  });
}
