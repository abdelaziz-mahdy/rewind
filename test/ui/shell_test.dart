import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/shell.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/nav_rail.dart';
import '../fakes/fake_capture_engine.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

/// The League game hub's content (integration card, auto-clip switch, event
/// matrix, clip list) is tall enough that the default test viewport leaves
/// its clip list outside the lazy list's build extent — see
/// `game_hub_screen_test.dart`'s identical helper for the full explanation.
Future<void> _pumpTall(WidgetTester t, Widget child) async {
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
    tmp = Directory.systemTemp.createTempSync('rewind_shell');
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

  Shell shell({
    String? error,
    ValueNotifier<bool>? bufferActive,
    VoidCallback? onOpenClipsFolder,
    List<AppInfo> capturableApps = const [],
    Future<void> Function(AppSettings)? onSettingsChanged,
    void Function(String bundleId)? onSetCaptureApp,
  }) =>
      Shell(
        coordinator: coordinator,
        library: library,
        captureError: error,
        // Idle by default: an un-paused buffer keeps the recorder cluster's
        // pulsing dot ticking forever, which would hang `pumpAndSettle`
        // (matches recorder_cluster_test.dart's own note on the same
        // widget).
        bufferActive: bufferActive ?? ValueNotifier<bool>(false),
        hotkeyLabel: 'Alt+F10',
        capturableApps: capturableApps,
        onSettingsChanged: onSettingsChanged ?? (_) async {},
        onOpenClipsFolder: onOpenClipsFolder ?? () {},
        onSetCaptureApp: onSetCaptureApp,
      );

  Clip clip(String path, String gameId, GameEventKind event, DateTime createdAt,
          {int sizeBytes = 1024}) =>
      Clip(
          path: '${tmp.path}/$path.mp4',
          gameId: gameId,
          event: event,
          createdAt: createdAt,
          sizeBytes: sizeBytes);

  Finder navItem(String id) => find.byKey(ValueKey('navItem:$id'));
  Finder navGame(String gameId) => find.byKey(ValueKey('navGame:$gameId'));

  // The event-kind filter chips can show the same uppercase badge text as a
  // clip tile (e.g. a "PENTA KILL" chip alongside a clip's "PENTA KILL"
  // badge) — scope badge assertions to the list itself to avoid ambiguity.
  Finder inList(Finder f) =>
      find.descendant(of: find.byKey(const ValueKey('clipsList')), matching: f);

  testWidgets('defaults to the All Clips destination showing the empty state',
      (t) async {
    await t.pumpWidget(_app(shell()));
    expect(find.textContaining('Alt+F10'), findsOneWidget);
    expect(find.text('All clips'), findsNothing); // empty state, no header
  });

  testWidgets('capture error hides the buffering indicator', (t) async {
    await t.pumpWidget(_app(shell(error: 'libobs init failed')));
    expect(find.textContaining('Buffering'), findsNothing);
    expect(find.text('Capture unavailable'), findsOneWidget);
  });

  testWidgets('paused buffer shows Paused and stops claiming Buffering',
      (t) async {
    final active = ValueNotifier<bool>(true);
    await t.pumpWidget(_app(shell(bufferActive: active)));
    expect(find.textContaining('Buffering'), findsOneWidget);
    active.value = false;
    await t.pump();
    expect(find.textContaining('Buffering'), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('capture error shows banner and disables Save', (t) async {
    await t.pumpWidget(_app(shell(error: 'libobs init failed')));
    expect(find.textContaining('libobs init failed'), findsOneWidget);
    final btn =
        t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save clip'));
    expect(btn.onPressed, isNull);
  });

  group('permission banner button', () {
    // Migrated from the old status_strip_test.dart: the permission banner
    // (`_ErrorBanner`) moved from the deck to the top of the content area
    // (see shell.dart), but its "coach the user to System Settings" button
    // is unchanged.
    testWidgets('present for a permission-related capture error', (t) async {
      await t
          .pumpWidget(_app(shell(error: 'Screen recording permission denied')));
      expect(
        find.text('Open Screen Recording Settings'),
        Platform.isMacOS ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('absent for a non-permission capture error', (t) async {
      await t.pumpWidget(_app(shell(error: 'libobs init failed')));
      expect(find.text('Open Screen Recording Settings'), findsNothing);
    });
  });

  testWidgets('a save error shows a SnackBar with the message', (t) async {
    await t.pumpWidget(_app(shell()));
    coordinator.lastSaveError.value = 'disk full';
    await t.pump(); // schedule the SnackBar
    await t.pump(); // let it animate in
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets('a second identical failure shows the SnackBar again', (t) async {
    await t.pumpWidget(_app(shell()));

    coordinator.lastSaveError.value = 'disk full';
    await t.pump();
    await t.pump();
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);

    // Let the first SnackBar fully dismiss, then repeat the exact failure the
    // way ClipCoordinator._reportSaveError does — null, then the same
    // message — since a plain re-set of an equal value is a no-op on
    // ValueNotifier and would never reach the listener.
    await t.pump(const Duration(seconds: 5));
    coordinator.lastSaveError.value = null;
    coordinator.lastSaveError.value = 'disk full';
    await t.pump();
    await t.pump();
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets(
      'a save error still shows its SnackBar while on a non-All-Clips '
      'destination — the listener lives in the Shell, not the old '
      'per-screen HomeScreen', (t) async {
    await t.pumpWidget(_app(shell()));
    await t.tap(navItem('settings'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    coordinator.lastSaveError.value = 'disk full';
    await t.pump();
    await t.pump();
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets('the Logs rail item opens the custom Logs screen', (t) async {
    await t.pumpWidget(_app(shell()));
    await t.tap(navItem('logs'));
    await t.pumpAndSettle();
    // Rewind's own logs viewer (its AppBar title), not the third-party
    // TalkerScreen.
    expect(find.widgetWithText(AppBar, 'Logs'), findsOneWidget);
  });

  testWidgets('rendering the shell does not pre-seed a game config', (t) async {
    // Merely showing "Buffering · N s" must not insert a 'desktop' (or any
    // other) row into settings — that would leak into Settings' per-game
    // section before a game has ever actually been configured.
    await t.pumpWidget(_app(shell()));
    expect(coordinator.settings.allConfigs, isEmpty);
  });

  group('rail', () {
    testWidgets('lists directory entries with clip counts', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
      library.add(
          clip('a', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(
          clip('b', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 2)));
      library.add(
          clip('c', 'desktop', GameEventKind.manual, DateTime(2026, 7, 3)));
      await t.pumpWidget(_app(shell()));

      expect(navGame('app:cs2'), findsOneWidget);
      expect(
          find.descendant(
              of: navGame('app:cs2'), matching: find.text('Counter-Strike 2')),
          findsOneWidget);
      expect(find.descendant(of: navGame('app:cs2'), matching: find.text('2')),
          findsOneWidget);
      expect(navGame('desktop'), findsOneWidget);
      expect(find.descendant(of: navGame('desktop'), matching: find.text('1')),
          findsOneWidget);
    });

    testWidgets('selecting a game filters the content to that game', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await _pumpTall(t, _app(shell()));

      // All Clips (the default destination) shows both.
      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);

      await t.tap(navGame('league_of_legends'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('League of Legends'), findsWidgets);
      // The hub is now a match grid: League's session shows as one card
      // (1 clip); the desktop clip is filtered out entirely.
      expect(inList(find.text('1 clip')), findsOneWidget);
      expect(inList(find.text('MANUAL')), findsNothing);
    });

    testWidgets('All Clips destination shows every game\'s clips', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(shell()));

      // Switch away to a game, then back to All Clips, to prove the
      // destination genuinely restores the full library rather than staying
      // filtered.
      await t.tap(navGame('league_of_legends'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(navItem('allClips'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
    });

    testWidgets('the Settings destination renders the embedded SettingsScreen',
        (t) async {
      await t.pumpWidget(_app(shell()));
      expect(find.text('Instant replay'), findsNothing);

      await t.tap(navItem('settings'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      // Capture is the default page; Hotkeys is reachable alongside it in
      // the sidebar (only the selected page's content is built at a time).
      expect(find.text('Instant replay'), findsOneWidget);
      expect(find.byKey(const ValueKey('settingsTab:Hotkey')), findsOneWidget);
    });

    testWidgets(
        'Settings is full-page: it replaces the rail entirely, and the '
        'close button returns to whatever destination was showing before',
        (t) async {
      await t.pumpWidget(_app(shell()));
      expect(find.byType(NavRail), findsOneWidget);

      await t.tap(navItem('settings'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.byType(NavRail), findsNothing);

      await t.tap(find.byKey(const ValueKey('settingsCloseButton')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.byType(NavRail), findsOneWidget);
      // Back on All Clips (the default destination, and the one showing
      // right before Settings was opened here).
      expect(find.text('Instant replay'), findsNothing);
    });

    testWidgets(
        'the close button returns to the game hub that was showing before '
        'Settings was opened, not always All Clips', (t) async {
      library.add(clip('a', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(shell()));

      await t.tap(navGame('league_of_legends'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('gameHubScreen:league_of_legends')),
          findsOneWidget);

      await t.tap(navItem('settings'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byType(NavRail), findsNothing);

      await t.tap(find.byKey(const ValueKey('settingsCloseButton')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const ValueKey('gameHubScreen:league_of_legends')),
          findsOneWidget);
    });

    testWidgets('the Supported Games screen renders for + Add game', (t) async {
      await t.pumpWidget(_app(shell()));
      await t.tap(navItem('addGame'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('Supported Games'), findsOneWidget);
    });
  });

  group('detected game banner', () {
    Finder banner(String gameId) =>
        find.byKey(ValueKey('detectedGameBanner:$gameId'));

    testWidgets(
        'appears for a catalog game detected running with no GameConfig yet',
        (t) async {
      coordinator.activeGameIds.value = {'app:cs2'};
      await t.pumpWidget(_app(shell()));

      expect(banner('app:cs2'), findsOneWidget);
      expect(
          find.textContaining('Counter-Strike 2 is running'), findsOneWidget);
    });

    testWidgets('absent once the game already has a GameConfig', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
      coordinator.activeGameIds.value = {'app:cs2'};
      await t.pumpWidget(_app(shell()));

      expect(banner('app:cs2'), findsNothing);
    });

    testWidgets('absent when no catalog game is running', (t) async {
      await t.pumpWidget(_app(shell()));
      expect(find.textContaining(' is running'), findsNothing);
    });

    testWidgets(
        'Record configures the game, sets the matching capture app, and '
        'opens its hub', (t) async {
      final settingsCalls = <AppSettings>[];
      String? capturedBundleId;
      coordinator.activeGameIds.value = {'app:cs2'};
      await t.pumpWidget(_app(shell(
        capturableApps: const [
          AppInfo(bundleId: 'com.valve.cs2', name: 'Counter-Strike 2', pid: 7),
        ],
        onSettingsChanged: (s) async => settingsCalls.add(s),
        onSetCaptureApp: (bundleId) => capturedBundleId = bundleId,
      )));

      await t
          .tap(find.byKey(const ValueKey('detectedGameBannerRecord:app:cs2')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(coordinator.settings.allConfigs.any((c) => c.gameId == 'app:cs2'),
          isTrue);
      expect(settingsCalls, isNotEmpty);
      expect(capturedBundleId, 'com.valve.cs2');
      expect(
          find.byKey(const ValueKey('gameHubScreen:app:cs2')), findsOneWidget);
    });

    testWidgets(
        'Record does not touch the capture app when nothing currently '
        'running matches the game', (t) async {
      String? capturedBundleId;
      coordinator.activeGameIds.value = {'app:cs2'};
      await t.pumpWidget(_app(shell(
        onSetCaptureApp: (bundleId) => capturedBundleId = bundleId,
      )));

      await t
          .tap(find.byKey(const ValueKey('detectedGameBannerRecord:app:cs2')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(capturedBundleId, isNull);
      expect(coordinator.settings.allConfigs.any((c) => c.gameId == 'app:cs2'),
          isTrue);
    });

    testWidgets('dismiss hides the banner for that game only', (t) async {
      coordinator.activeGameIds.value = {'app:cs2', 'app:dota2'};
      await t.pumpWidget(_app(shell()));

      await t
          .tap(find.byKey(const ValueKey('detectedGameBannerDismiss:app:cs2')));
      await t.pump();

      expect(banner('app:cs2'), findsNothing);
      expect(banner('app:dota2'), findsOneWidget);
    });
  });
}
