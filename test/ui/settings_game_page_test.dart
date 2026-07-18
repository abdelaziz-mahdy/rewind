import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/settings/app_settings.dart';
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
        'a process-detected game (no live vendor API) never shows an event '
        'matrix, even under Highlights', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      // Highlights is already selected by GameConfig's default, and there's
      // still no matrix to show.
      expect(
          find.byKey(const ValueKey('gameSettingsEventMatrix')), findsNothing);

      await t.tap(find.byKey(const ValueKey('captureMode:manual')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('captureMode:highlights')));
      await t.pump();

      expect(
          find.byKey(const ValueKey('gameSettingsEventMatrix')), findsNothing);
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
        'shown under Highlights when eventGroupsFor is empty, in place of '
        'the delay row', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      // Highlights is already selected by GameConfig's default.
      expect(
          find.byKey(const ValueKey('noAutoClipEventsNote')), findsOneWidget);
      expect(
          find.textContaining('clips save with your hotkey'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('postEventDelayDropdown')), findsNothing);
    });

    testWidgets('hidden under Manual only', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        gameEntries: const [_valorant],
        initialGameId: 'valorant',
      )));

      await t.tap(find.byKey(const ValueKey('captureMode:manual')));
      await t.pump();

      expect(find.byKey(const ValueKey('noAutoClipEventsNote')), findsNothing);
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
