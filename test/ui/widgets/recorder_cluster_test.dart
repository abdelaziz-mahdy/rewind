import 'dart:io' show Directory;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/obs/display_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/recorder_cluster.dart';

import '../../fakes/fake_capture_engine.dart';

const _displays = [
  DisplayInfo(uuid: 'display-1', width: 1920, height: 1080, isMain: true),
  DisplayInfo(uuid: 'display-2', width: 2560, height: 1440, isMain: false),
];

const _apps = [
  AppInfo(bundleId: 'com.example.one', name: 'App One', pid: 1),
  AppInfo(bundleId: 'com.example.two', name: 'App Two', pid: 2),
];

void main() {
  late Directory tmp;
  late ClipCoordinator Function(AppSettings settings) makeCoordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_recorder_cluster');
    makeCoordinator = (settings) {
      final library = ClipLibrary(clipsDir: tmp);
      return ClipCoordinator(
        registry: GameRegistry(sources: []),
        library: library,
        storage: StorageManager(library),
        settings: settings,
        outDir: tmp.path,
        engine: FakeCaptureEngine(),
      );
    };
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // Sized to the real 220 px rail so text-overflow/ellipsis behavior in
  // manual testing matches, though none of these assertions depend on it.
  Widget app(Widget child) => MaterialApp(
        theme: rewindTheme(),
        home: Scaffold(body: SizedBox(width: 220, child: child)),
      );

  // The cluster's pulsing "recording" dot runs an AnimationController.
  // repeat() that never settles on its own — unlike pushing a full route
  // (which pauses tickers behind it via TickerMode), a popup menu doesn't
  // stop it — so `pumpAndSettle` would hang forever waiting for a frame
  // that's never the last one. Bounded pumps step through the popup menu's
  // (finite) open/close transition instead.
  Future<void> settleMenu(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  // Scopes a label assertion/tap to the source line itself, not any popup
  // menu item — a picked app's name (e.g. "App Two") reads identically on
  // both, and briefly coexists mid-close-animation.
  Finder sourceLine(String text) => find.descendant(
      of: find.byKey(const ValueKey('recorderSourceLine')),
      matching: find.text(text));

  RecorderCluster cluster({
    required AppSettings settings,
    List<DisplayInfo> displays = _displays,
    List<AppInfo> capturableApps = const [],
    String? captureError,
    Future<void> Function(AppSettings)? onSettingsChanged,
    ValueListenable<int>? settingsRevision,
    // Lets a test grab the coordinator before pumping, to set activeGame /
    // autoSwitchedAppName ahead of time.
    ClipCoordinator? coordinatorOverride,
  }) =>
      RecorderCluster(
        coordinator: coordinatorOverride ?? makeCoordinator(settings),
        captureError: captureError,
        displays: displays,
        capturableApps: capturableApps,
        onSettingsChanged: onSettingsChanged ?? (_) async {},
        onOpenSettings: () {},
        settingsRevision: settingsRevision,
      );

  group('capture-source line', () {
    testWidgets('shows the current source: main display by default', (t) async {
      await t.pumpWidget(app(cluster(settings: AppSettings())));
      expect(sourceLine('Display 1'), findsOneWidget);
    });

    testWidgets('sits ABOVE the Save clip and Record buttons', (t) async {
      // The picker decides what those buttons capture (source → actions),
      // and as a naked text line at the cluster's bottom it was
      // undiscoverable — the maintainer couldn't find it.
      await t.pumpWidget(app(cluster(settings: AppSettings())));
      final pickerBottom =
          t.getBottomLeft(find.byKey(const ValueKey('recorderSourceLine'))).dy;
      final saveTop =
          t.getTopLeft(find.widgetWithText(FilledButton, 'Save clip')).dy;
      final recordTop =
          t.getTopLeft(find.byKey(const ValueKey('recordButton'))).dy;
      expect(pickerBottom, lessThanOrEqualTo(saveTop));
      expect(saveTop, lessThan(recordTop));
    });

    testWidgets('shows the app name when an app target is set', (t) async {
      await t.pumpWidget(app(cluster(
        settings: AppSettings(captureAppBundleId: 'com.example.two'),
        capturableApps: _apps,
      )));
      expect(sourceLine('App Two'), findsOneWidget);
    });

    testWidgets('hidden entirely when there are no displays to pick between',
        (t) async {
      await t.pumpWidget(
          app(cluster(settings: AppSettings(), displays: const [])));
      expect(find.byIcon(Icons.desktop_windows_outlined), findsNothing);
      expect(find.byIcon(Icons.apps_outlined), findsNothing);
    });

    testWidgets(
        'picking an app updates settings.captureAppBundleId and '
        'fires onSettingsChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      await t.tap(find.text('App Two').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      expect(calls.last.captureAppBundleId, 'com.example.two');
    });

    testWidgets(
        'picking an app also creates a GameConfig for it, reusing an '
        'existing catalog gameId when the app matches one', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      const catalogApp =
          AppInfo(bundleId: 'com.valve.cs2', name: 'Counter-Strike 2', pid: 3);
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: const [..._apps, catalogApp],
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      await t.tap(find.text('Counter-Strike 2').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      final cfg =
          settings.allConfigs.where((c) => c.gameId == 'app:cs2').toList();
      expect(cfg, hasLength(1));
      expect(cfg.single.processMatch, 'Counter-Strike 2');
    });

    testWidgets('picking a non-catalog app mints a fresh app:<slug> GameConfig',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      await t.tap(find.text('App Two').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      final cfg =
          settings.allConfigs.where((c) => c.gameId == 'app:app_two').toList();
      expect(cfg, hasLength(1));
      expect(cfg.single.processMatch, 'App Two');
      // The picked app's real casing survives: as the persisted source
      // label, and as the fresh config's display name (the app:<slug>
      // gameId alone would render as "App:app Two").
      expect(settings.captureAppName, 'App Two');
      expect(cfg.single.displayName, 'App Two');
    });

    testWidgets(
        'picking an app also captures its icon onto the GameConfig for the '
        'rail logo', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      const iconApp = AppInfo(
        bundleId: 'com.example.three',
        name: 'App Three',
        pid: 4,
        iconPath: '/Applications/App Three.app/Contents/Resources/icon.icns',
      );
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: const [..._apps, iconApp],
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      await t.tap(find.text('App Three').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      final cfg = settings.allConfigs.where((c) => c.gameId == 'app:app_three');
      expect(cfg.single.iconPath,
          '/Applications/App Three.app/Contents/Resources/icon.icns');
    });

    testWidgets('a Wine app (no bundle, no icon) leaves iconPath null',
        (t) async {
      const crossover = AppInfo(
          bundleId: 'com.codeweavers.CrossOver', name: 'CrossOver', pid: 10);
      const wineGame = AppInfo(bundleId: '', name: 'SomeGame.exe', pid: 11);
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: const [crossover, wineGame],
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      await t.tap(find.text('SomeGame.exe').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      final cfg =
          settings.allConfigs.where((c) => c.gameId == 'app:somegame_exe');
      expect(cfg.single.iconPath, isNull);
    });

    testWidgets(
        'picking League never captures its app icon: it IS Riot\'s official '
        'logo, which Riot policy forbids using', (t) async {
      const league = AppInfo(
        bundleId: 'com.riotgames.LeagueClientUx',
        name: 'League of Legends',
        pid: 12,
        iconPath: '/Applications/League of Legends.app/icon.icns',
      );
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: const [..._apps, league],
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      await t.tap(find.text('League of Legends').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      final cfg =
          settings.allConfigs.where((c) => c.gameId == 'app:league_of_legends');
      expect(cfg.single.iconPath, isNull);
    });

    testWidgets(
        'the label prefers the stored captureAppName over a bundle-id '
        'lookup (ambiguous for Wine apps sharing one bundle id)', (t) async {
      // Two entries share CrossOver's bundle id: the translator itself and
      // a Windows game running under it. A bundle-id lookup would show
      // whichever is listed first ("CrossOver") — not what the user picked.
      const crossover = AppInfo(
          bundleId: 'com.codeweavers.CrossOver', name: 'CrossOver', pid: 10);
      const wineGame = AppInfo(
          bundleId: 'com.codeweavers.CrossOver',
          name: 'PenguinHotel-Win64-Shipping',
          pid: 11);
      await t.pumpWidget(app(cluster(
        settings: AppSettings(
          captureAppBundleId: 'com.codeweavers.CrossOver',
          captureAppName: 'PenguinHotel-Win64-Shipping',
        ),
        capturableApps: const [crossover, wineGame],
      )));
      expect(sourceLine('PenguinHotel-Win64-Shipping'), findsOneWidget);
      expect(sourceLine('CrossOver'), findsNothing);
    });

    testWidgets(
        'picking a Wine app (empty bundleId) clears the persisted app '
        'target, registers the game, and starts WINDOW capture of it',
        (t) async {
      // Wine programs enumerate with an empty bundle id (see
      // AppInfo.bundleId): SCK app capture can't target them, so the pick
      // must clear any app target — never store "" — register the game
      // (detection, rail row, clip filing), and capture the game's WINDOW
      // via the coordinator so a shared display's Discord etc. never leaks
      // into clips.
      const wineGame = AppInfo(
          bundleId: '',
          name: 'PenguinHotel-Win64-Shipping',
          pid: 99,
          windowId: 4242);
      final settings = AppSettings(
          captureAppBundleId: 'com.example.two', captureAppName: 'App Two');
      final coordinator = makeCoordinator(settings);
      final engine = coordinator.engine as FakeCaptureEngine;
      await t.pumpWidget(app(cluster(
        settings: settings,
        coordinatorOverride: coordinator,
        capturableApps: [..._apps, wineGame],
      )));

      await t.tap(sourceLine('App Two'));
      await settleMenu(t);
      await t.tap(find.text('PenguinHotel-Win64-Shipping').last);
      await settleMenu(t);

      expect(settings.captureAppBundleId, isNull);
      expect(settings.captureAppName, isNull);
      final cfg = settings.allConfigs
          .where((c) => c.gameId == 'app:penguinhotel_win64_shipping')
          .toList();
      expect(cfg, hasLength(1));
      expect(cfg.single.processMatch, 'PenguinHotel-Win64-Shipping');
      expect(cfg.single.displayName, 'PenguinHotel-Win64-Shipping');
      expect(engine.captureWindowCalls, [4242]);
      expect(
          coordinator.autoSwitchedAppName.value, 'PenguinHotel-Win64-Shipping');
    });

    testWidgets('picking a display clears the stored captureAppName',
        (t) async {
      final settings = AppSettings(
          captureAppBundleId: 'com.example.two', captureAppName: 'App Two');
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: _apps,
      )));

      await t.tap(sourceLine('App Two'));
      await settleMenu(t);
      await t.tap(find.textContaining('Entire Display 1'));
      await settleMenu(t);

      expect(settings.captureAppBundleId, isNull);
      expect(settings.captureAppName, isNull);
    });

    testWidgets(
        'the menu re-enumerates via listApps on open, so an app launched '
        'after startup appears', (t) async {
      // Static snapshot has only App One; the live lister also knows the
      // game that launched later.
      const lateGame = AppInfo(
          bundleId: 'com.codeweavers.CrossOver',
          name: 'PenguinHotel-Win64-Shipping',
          pid: 99);
      await t.pumpWidget(app(RecorderCluster(
        coordinator: makeCoordinator(AppSettings()),
        displays: _displays,
        capturableApps: [_apps[0]],
        listApps: () => [_apps[0], lateGame],
        onSettingsChanged: (_) async {},
        onOpenSettings: () {},
      )));

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      expect(find.text('PenguinHotel-Win64-Shipping'), findsOneWidget);
    });

    testWidgets(
        'picking a display writes captureDisplayUuid and clears '
        'captureAppBundleId', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(captureAppBundleId: 'com.example.one');
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(sourceLine('App One'));
      await settleMenu(t);
      await t.tap(find.text('Entire Display 2 — 2560×1440').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      expect(calls.last.captureDisplayUuid, 'display-2');
      expect(calls.last.captureAppBundleId, isNull);
    });
  });

  group('buffer quick-set', () {
    testWidgets(
        'picking 60s updates defaultBufferSeconds and fires '
        'onSettingsChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(app(cluster(
        settings: settings,
        onSettingsChanged: (s) async => calls.add(s),
      )));

      expect(find.textContaining('Buffering · 30 s'), findsOneWidget);
      await t.tap(find.textContaining('Buffering · 30 s'));
      await settleMenu(t);
      await t.tap(find.text('60 s').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      expect(calls.last.defaultBufferSeconds, 60);
    });

    testWidgets(
        'with an active game, picking 60s writes THAT game\'s per-game '
        'buffer length — not the default, which bufferSecondsFor would '
        'never read again once a per-game row exists', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      final coordinator = makeCoordinator(settings);
      coordinator.activeGame.value = 'league_of_legends';
      await t.pumpWidget(app(cluster(
        settings: settings,
        coordinatorOverride: coordinator,
        onSettingsChanged: (s) async => calls.add(s),
      )));

      expect(find.textContaining('Buffering · 30 s'), findsOneWidget);
      await t.tap(find.textContaining('Buffering · 30 s'));
      await settleMenu(t);
      await t.tap(find.text('60 s').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      expect(settings.bufferSecondsFor('league_of_legends'), 60);
      expect(settings.defaultBufferSeconds, 30);
    });
  });

  group('settings changes refresh labels immediately (settingsRevision)', () {
    testWidgets(
        'picking a source updates the line label without waiting '
        'for an unrelated rebuild', (t) async {
      final settings = AppSettings();
      final revision = ValueNotifier<int>(0);
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: _apps,
        settingsRevision: revision,
        onSettingsChanged: (s) async => revision.value++,
      )));

      expect(sourceLine('Display 1'), findsOneWidget);
      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      await t.tap(find.text('App Two').last);
      await settleMenu(t);

      expect(sourceLine('App Two'), findsOneWidget);
      expect(sourceLine('Display 1'), findsNothing);
    });

    testWidgets(
        'picking a buffer length updates the readout without '
        'waiting for an unrelated rebuild', (t) async {
      final settings = AppSettings();
      final revision = ValueNotifier<int>(0);
      await t.pumpWidget(app(cluster(
        settings: settings,
        settingsRevision: revision,
        onSettingsChanged: (s) async => revision.value++,
      )));

      expect(find.textContaining('Buffering · 30 s'), findsOneWidget);
      await t.tap(find.textContaining('Buffering · 30 s'));
      await settleMenu(t);
      await t.tap(find.text('60 s').last);
      await settleMenu(t);

      expect(find.textContaining('Buffering · 60 s'), findsOneWidget);
    });
  });

  group('auto-switch line', () {
    testWidgets(
        'shows the auto-switched app name (with "(auto)") ahead of the '
        'persisted source while the coordinator is following a game',
        (t) async {
      final settings = AppSettings(captureAppBundleId: 'com.example.one');
      final coordinator = makeCoordinator(settings);
      coordinator.autoSwitchedAppName.value = 'Stub App One';
      await t.pumpWidget(app(cluster(
        settings: settings,
        capturableApps: _apps,
        coordinatorOverride: coordinator,
      )));

      expect(find.text('Stub App One (auto)'), findsOneWidget);
      // Exact match: the persisted "App One" is a substring of the
      // auto-switched label, so this only proves the *plain* (non-auto)
      // label isn't also rendered somewhere.
      expect(find.text('App One'), findsNothing);
    });
  });

  group('record button', () {
    testWidgets('idle state shows an outlined "Record" button', (t) async {
      await t.pumpWidget(app(cluster(settings: AppSettings())));
      expect(find.text('Record'), findsOneWidget);
      final btn =
          t.widget<OutlinedButton>(find.byKey(const ValueKey('recordButton')));
      expect(btn.onPressed, isNotNull);
    });

    testWidgets(
        'tapping starts a recording, flipping to the filled elapsed state',
        (t) async {
      final coordinator = makeCoordinator(AppSettings());
      await t.pumpWidget(app(cluster(
        settings: AppSettings(),
        coordinatorOverride: coordinator,
      )));

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();

      expect(coordinator.isRecording.value, isTrue);
      expect(find.text('Record'), findsNothing);
      expect(find.textContaining('0:00'), findsOneWidget);

      // Stop before the test ends so no Timer is left pending (bounded
      // pumps only — see the file's pumpAndSettle caveat).
      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.pump();
    });

    testWidgets('the elapsed readout ticks once a second while recording',
        (t) async {
      final coordinator = makeCoordinator(AppSettings());
      await t.pumpWidget(app(cluster(
        settings: AppSettings(),
        coordinatorOverride: coordinator,
      )));

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      expect(find.textContaining('0:00'), findsOneWidget);

      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('0:01'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.pump();
    });

    testWidgets(
        'tapping again while recording stops it and saves a recording clip',
        (t) async {
      final coordinator = makeCoordinator(AppSettings());
      await t.pumpWidget(app(cluster(
        settings: AppSettings(),
        coordinatorOverride: coordinator,
      )));

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.pump(); // let the async stop/save chain settle

      expect(coordinator.isRecording.value, isFalse);
      expect(find.text('Record'), findsOneWidget);
    });

    testWidgets('disabled when there is a capture error', (t) async {
      await t.pumpWidget(
          app(cluster(settings: AppSettings(), captureError: 'boom')));
      final btn =
          t.widget<OutlinedButton>(find.byKey(const ValueKey('recordButton')));
      expect(btn.onPressed, isNull);
    });
  });
}
