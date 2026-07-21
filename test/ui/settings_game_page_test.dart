import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/game_directory.dart';
import 'package:rewind/src/ui/settings_screen.dart';
import 'package:rewind/src/ui/theme.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

const _league = GameEntry(
  gameId: 'league_of_legends',
  displayName: 'League of Legends',
  detection: {DetectionMethod.liveClientApi, DetectionMethod.processWatch},
  active: false,
  clipCount: 0,
  totalSizeBytes: 0,
);

const _valorant = GameEntry(
  gameId: 'valorant',
  displayName: 'VALORANT',
  detection: {DetectionMethod.processWatch},
  processMatch: 'VALORANT-Win64-Shipping.exe',
  active: false,
  clipCount: 0,
  totalSizeBytes: 0,
);

/// Same game, but with the displayName [buildGameDirectory] would have
/// produced from an already-saved `GameConfig.displayName` override — used
/// by tests that pre-seed `settings` with an override, since a real caller
/// (`Shell`) always derives `gameEntries` FROM `settings`, but these widget
/// tests pass a hand-built [GameEntry] independently of it.
const _valorantRenamed = GameEntry(
  gameId: 'valorant',
  displayName: 'My VALORANT',
  detection: {DetectionMethod.processWatch},
  processMatch: 'VALORANT-Win64-Shipping.exe',
  active: false,
  clipCount: 0,
  totalSizeBytes: 0,
);

/// Opens the Advanced options disclosure on whichever page is currently
/// showing — same helper shape as `settings_screen_test.dart`'s own
/// `openAdvanced`.
Future<void> _openAdvanced(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('advancedOptionsToggle')));
  await t.pumpAndSettle();
}

void main() {
  // Same viewport widening as settings_screen_test.dart: the Capture-mode
  // cards + buffer row + advanced disclosure push content below the default
  // 800x600 test viewport.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!;
    view.physicalSize = const Size(1000, 1400);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!
        .reset();
  });

  group('MY GAMES sidebar', () {
    testWidgets('is absent when gameEntries is empty', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(find.text('MY GAMES'), findsNothing);
    });

    testWidgets('lists one item per game entry, same order as given',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league, _valorant],
      )));

      expect(find.text('MY GAMES'), findsOneWidget);
      expect(find.byKey(const ValueKey('settingsGame:league_of_legends')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('settingsGame:valorant')), findsOneWidget);
    });

    testWidgets('selecting a game shows its page and hides the Capture page',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
      )));

      expect(find.text('Instant replay'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('settingsGame:league_of_legends')));
      await t.pump();

      // Two now: the still-visible sidebar row plus the page title.
      expect(find.text('League of Legends'), findsNWidgets(2));
      expect(
          find.textContaining(
              'everything not set here follows your Capture defaults'),
          findsOneWidget);
      expect(find.text('Instant replay'), findsNothing);
    });
  });

  group('Name field (Task 28: renameable game display names)', () {
    TextEditingController nameController(WidgetTester t) => t
        .widget<TextField>(find.byKey(const ValueKey('gameNameField')))
        .controller!;

    testWidgets(
        'renders for a renameable game, prefilled with its current name',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      expect(find.byKey(const ValueKey('gameNameField')), findsOneWidget);
      expect(nameController(t).text, 'VALORANT');
    });

    testWidgets(
        'is hidden for a descriptor-registered game (League) — not '
        'renameable in v1: renaming it would desync its two merged gameIds\' '
        'names', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      expect(find.byKey(const ValueKey('gameNameField')), findsNothing);
    });

    testWidgets(
        'committing a new name on blur writes GameConfig.displayName, fires '
        'onChanged, and updates the page title + sidebar row live', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      await t.enterText(
          find.byKey(const ValueKey('gameNameField')), 'My VALORANT');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();

      expect(settings.configFor('valorant').displayName, 'My VALORANT');
      expect(calls, isNotEmpty);
      expect(calls.last.configFor('valorant').displayName, 'My VALORANT');
      // Both the page title and the still-visible sidebar row must show the
      // new name immediately — no need to close and reopen Settings.
      expect(find.text('My VALORANT'), findsAtLeastNWidgets(2));
      expect(
          find.descendant(
            of: find.byKey(const ValueKey('settingsGame:valorant')),
            matching: find.text('My VALORANT'),
          ),
          findsOneWidget);
    });

    testWidgets(
        'clearing the field on blur removes the override (writes null, '
        'never an empty string) and snaps the field back to the derived '
        'name', (t) async {
      final settings = AppSettings();
      settings.setConfig(
          GameConfig(gameId: 'valorant', displayName: 'My VALORANT'));
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorantRenamed],
        initialGameId: 'valorant',
      )));

      expect(nameController(t).text, 'My VALORANT');

      await t.enterText(find.byKey(const ValueKey('gameNameField')), '   ');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();

      expect(settings.configFor('valorant').displayName, isNull);
      expect(nameController(t).text, 'Valorant');
    });

    testWidgets('leaving the field unchanged does not fire onChanged',
        (t) async {
      final calls = <AppSettings>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (s) async => calls.add(s),
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      await t.tap(find.byKey(const ValueKey('gameNameField')));
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();

      expect(calls, isEmpty);
    });
  });

  testWidgets('initialGameId opens Settings directly on that game\'s page',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      gameEntries: const [_league],
      initialGameId: 'league_of_legends',
    )));

    // Sidebar row + page title.
    expect(find.text('League of Legends'), findsNWidgets(2));
    expect(find.text('Instant replay'), findsNothing);
  });

  testWidgets(
      'an initialGameId not present in gameEntries falls back to Capture',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      gameEntries: const [_league],
      initialGameId: 'not_a_configured_game',
    )));

    expect(find.text('Instant replay'), findsOneWidget);
  });

  group('Capture mode', () {
    testWidgets(
        'defaults to Highlights selected (GameConfig.autoClip default) with '
        'its chips already visible', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      expect(find.text('KILL'), findsOneWidget);
    });

    testWidgets('tapping Manual only writes autoClip=false and fires onChanged',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      await t.tap(find.byKey(const ValueKey('captureMode:manual')));
      await t.pump();

      expect(settings.configFor('league_of_legends').autoClip, isFalse);
      expect(calls, isNotEmpty);
      expect(calls.last.configFor('league_of_legends').autoClip, isFalse);
    });

    testWidgets('chips hide under Manual and reappear under Highlights',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      expect(find.byKey(const ValueKey('gameSettingsEventMatrix')),
          findsOneWidget);

      await t.tap(find.byKey(const ValueKey('captureMode:manual')));
      await t.pump();
      expect(
          find.byKey(const ValueKey('gameSettingsEventMatrix')), findsNothing);

      await t.tap(find.byKey(const ValueKey('captureMode:highlights')));
      await t.pump();
      expect(find.byKey(const ValueKey('gameSettingsEventMatrix')),
          findsOneWidget);
    });

    testWidgets('tapping a chip writes enabledEvents and fires onChanged',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      expect(
          settings
              .configFor('league_of_legends')
              .enabledEvents
              .contains(GameEventKind.dragonKill),
          isFalse);

      await t.tap(find.byKey(const ValueKey('eventToggle:dragonKill')));
      await t.pump();

      expect(
          settings
              .configFor('league_of_legends')
              .enabledEvents
              .contains(GameEventKind.dragonKill),
          isTrue);
      expect(calls, isNotEmpty);

      // Untoggling removes it again.
      await t.tap(find.byKey(const ValueKey('eventToggle:dragonKill')));
      await t.pump();
      expect(
          settings
              .configFor('league_of_legends')
              .enabledEvents
              .contains(GameEventKind.dragonKill),
          isFalse);
    });

    testWidgets(
        'a process-detected game (no live vendor API) offers Manual + Full '
        'session, but NOT Highlights (no event feed to auto-clip)', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      // Manual and Full session apply to any game; Highlights needs events.
      expect(find.byKey(const ValueKey('captureMode:manual')), findsOneWidget);
      expect(find.byKey(const ValueKey('captureMode:full')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('captureMode:highlights')), findsNothing);
      expect(
          find.byKey(const ValueKey('gameSettingsEventMatrix')), findsNothing);
      // And a note explaining why Highlights is absent.
      expect(
          find.byKey(const ValueKey('noAutoClipEventsNote')), findsOneWidget);
    });

    testWidgets('Full session card is offered for a live-API game too',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));
      expect(find.byKey(const ValueKey('captureMode:manual')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('captureMode:highlights')), findsOneWidget);
      expect(find.byKey(const ValueKey('captureMode:full')), findsOneWidget);
    });

    testWidgets(
        'picking Full session writes recordFullSession and clears '
        'autoClip', (t) async {
      final calls = <AppSettings>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (s) async => calls.add(s),
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      await t.tap(find.byKey(const ValueKey('captureMode:full')));
      await t.pump();

      final cfg = calls.last.configFor('league_of_legends');
      expect(cfg.recordFullSession, isTrue);
      expect(cfg.autoClip, isFalse);
      // The Highlights event matrix is hidden under Full session.
      expect(
          find.byKey(const ValueKey('gameSettingsEventMatrix')), findsNothing);
      expect(find.byKey(const ValueKey('fullSessionNote')), findsOneWidget);
    });
  });

  group('Buffer length', () {
    testWidgets('shows "Use default" when no override has been made yet',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(defaultBufferSeconds: 30),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      expect(find.textContaining('Use default (30 s)'), findsOneWidget);
    });

    testWidgets(
        'picking 60 s writes the per-game override and fires '
        'onChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      await t.tap(find.byKey(const ValueKey('gameBufferDropdown')));
      await t.pumpAndSettle();
      await t.tap(find.text('60 s').last);
      await t.pumpAndSettle();

      expect(settings.configFor('league_of_legends').bufferSeconds, 60);
      expect(calls, isNotEmpty);
    });
  });

  group('Post-event delay', () {
    testWidgets('defaults to 5 s when no override has been made yet',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      final dropdown = t.widget<DropdownButtonFormField<int>>(
          find.byKey(const ValueKey('postEventDelayDropdown')));
      expect(dropdown.initialValue, 5);
      expect(
          find.textContaining(
              'A follow-up kill during this window extends the same clip.'),
          findsOneWidget);
    });

    testWidgets(
        'picking 8 s writes the per-game override and fires '
        'onChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      await t.tap(find.byKey(const ValueKey('postEventDelayDropdown')));
      await t.pumpAndSettle();
      await t.tap(find.text('8 s').last);
      await t.pumpAndSettle();

      expect(settings.configFor('league_of_legends').postEventSeconds, 8);
      expect(calls, isNotEmpty);
      expect(calls.last.configFor('league_of_legends').postEventSeconds, 8);
    });

    testWidgets('hidden for a process-detected game (no event matrix to delay)',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      expect(
          find.byKey(const ValueKey('postEventDelayDropdown')), findsNothing);
    });

    testWidgets('hidden under Manual only, reappears under Highlights',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      expect(
          find.byKey(const ValueKey('postEventDelayDropdown')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('captureMode:manual')));
      await t.pump();
      expect(
          find.byKey(const ValueKey('postEventDelayDropdown')), findsNothing);

      await t.tap(find.byKey(const ValueKey('captureMode:highlights')));
      await t.pump();
      expect(
          find.byKey(const ValueKey('postEventDelayDropdown')), findsOneWidget);
    });
  });

  group('No auto-clip events note (process-detected games)', () {
    testWidgets(
        'shown unconditionally in place of the Capture mode section, with '
        'no delay row', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      expect(
          find.byKey(const ValueKey('noAutoClipEventsNote')), findsOneWidget);
      expect(find.textContaining('no highlights to auto-clip'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('postEventDelayDropdown')), findsNothing);
    });

    testWidgets('never shown for a live-API game (League always has groups)',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      expect(find.byKey(const ValueKey('noAutoClipEventsNote')), findsNothing);
    });
  });

  group('Advanced options — Detection', () {
    testWidgets('reports Live Client API for League', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_league],
        initialGameId: 'league_of_legends',
      )));

      await _openAdvanced(t);
      expect(find.text('Live Client API (automatic)'), findsOneWidget);
    });

    testWidgets('reports the process match for a process-detected game',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      await _openAdvanced(t);
      expect(find.text('Process: VALORANT-Win64-Shipping.exe'), findsOneWidget);
    });
  });
}
