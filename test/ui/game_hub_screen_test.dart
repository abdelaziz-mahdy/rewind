import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/game_hub_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart' show formatSize;
import '../fakes/fake_capture_engine.dart';
import '../fakes/fake_game_source.dart';

Widget _app(Widget child) =>
    MaterialApp(theme: rewindTheme(), home: Scaffold(body: child));

/// The hub's content is a single scrollable page (header, integration card,
/// capture settings card, clip list) — League's version, with the auto-clip
/// switch and event matrix, is tall enough that the default test viewport
/// leaves the clip list and lower matrix groups outside the sliver's build
/// extent (a lazily-built list never realizes off-screen children, test or
/// not). Widening the test surface, rather than scrolling per-assertion,
/// keeps every test able to just `find` what it needs.
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

  // The header's status pill and the integration card both name the
  // detection method (e.g. "LIVE CLIENT API") — a compact glance vs. the
  // full explanation — so scope method-label assertions to the card to
  // avoid ambiguous matches against the pill.
  Finder inCard(Finder f) => find.descendant(
      of: find.byKey(const ValueKey('integrationCard')), matching: f);

  Finder inLiveEvents(Finder f) => find.descendant(
      of: find.byKey(const ValueKey('liveEventsSlot')), matching: f);

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

  group('integration status card per detection method', () {
    testWidgets(
        'League merged row shows both the vendor API and process detection',
        (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'league_of_legends'));
      coordinator.activeGameIds.value = {'app:league_of_legends'};
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(inCard(find.text('LIVE CLIENT API')), findsOneWidget);
      expect(inCard(find.text('In match — connected to 127.0.0.1:2999')),
          findsOneWidget);
      expect(
          inCard(find.textContaining(
              'Also detected via process — watching for LeagueClientUx')),
          findsOneWidget);
    });

    testWidgets('League shows the waiting state when inactive', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'league_of_legends'));
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(
          inCard(find.textContaining('Waiting for a match')), findsOneWidget);
    });

    testWidgets('catalog game shows its processMatch and a hotkey-only note',
        (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(inCard(find.text('PROCESS DETECTION')), findsOneWidget);
      expect(inCard(find.text('Watching for cs2')), findsOneWidget);
      expect(
          inCard(
              find.text('No event API for this game — clips are hotkey-only.')),
          findsOneWidget);
    });

    testWidgets('catalog game shows "Running now" while active', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
      coordinator.activeGameIds.value = {'app:cs2'};
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(inCard(find.text('Running now')), findsOneWidget);
    });

    testWidgets('desktop shows manual capture with the hotkey label',
        (t) async {
      await _pump(t, _app(hub(gameId: 'desktop')));

      expect(inCard(find.text('MANUAL CAPTURE')), findsOneWidget);
      expect(
          inCard(
              find.text('Clips saved with Alt+F10 while no game is detected.')),
          findsOneWidget);
    });
  });

  group('capture settings', () {
    testWidgets('a per-game buffer edit fires onSettingsChanged', (t) async {
      final calls = <AppSettings>[];
      await _pump(
          t,
          _app(hub(
            gameId: 'app:cs2',
            onSettingsChanged: (s) async => calls.add(s),
          )));

      await t.tap(find.text('60 s'));
      await t.pump();

      expect(calls, isNotEmpty);
      expect(coordinator.settings.configFor('app:cs2').bufferSeconds, 60);
    });

    testWidgets('the event matrix and auto-clip switch appear only for League',
        (t) async {
      await _pump(t, _app(hub(gameId: 'league_of_legends')));
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
      expect(find.byKey(const ValueKey('gameHubAutoClipSwitch')), findsNothing);
      expect(find.byKey(const ValueKey('gameHubEventMatrix')), findsNothing);

      await _pump(t, _app(hub(gameId: 'desktop')));
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

  group('clip list', () {
    testWidgets('scopes the list to this game only', (t) async {
      library.add(
          clip('a', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('PENTA KILL')), findsNothing);
    });

    testWidgets('League\'s hub also includes the catalog gameId\'s clips',
        (t) async {
      library.add(clip('a', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 1)));
      library.add(clip('b', 'app:league_of_legends', GameEventKind.manual,
          DateTime(2026, 7, 2)));
      await _pump(t, _app(hub(gameId: 'league_of_legends')));

      expect(inList(find.text('PENTA KILL')), findsOneWidget);
      expect(inList(find.text('MANUAL')), findsOneWidget);
    });

    testWidgets('an event-kind chip filters the scoped list', (t) async {
      library.add(
          clip('a', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 1)));
      library
          .add(clip('b', 'app:cs2', GameEventKind.other, DateTime(2026, 7, 2)));
      await _pump(t, _app(hub(gameId: 'app:cs2')));

      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('OTHER')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('eventFilterChip:manual')));
      await t.pump();

      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('OTHER')), findsNothing);
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
    });

    testWidgets('never appears for non-League games (no vendor event source)',
        (t) async {
      await _pump(t, _app(hub(gameId: 'app:cs2')));
      expect(find.byKey(const ValueKey('liveEventsSlot')), findsNothing);
    });
  });
}
