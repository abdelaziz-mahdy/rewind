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

      final headers = inList(find.textContaining('MATCH · '));
      expect(headers, findsNWidgets(2));
      expect(inList(find.textContaining('2 CLIPS')), findsOneWidget);
      expect(inList(find.textContaining('· 1 CLIP')), findsOneWidget);
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
