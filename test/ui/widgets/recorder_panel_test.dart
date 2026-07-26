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
import 'package:rewind/src/ui/widgets/recorder_panel.dart';

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
    tmp = Directory.systemTemp.createTempSync('rewind_transport_deck');
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

  // The deck spans the window, so these render at the default 800x600 test
  // surface rather than the 220 px box the old rail-bound cluster used. At
  // 800 the hotkey cap is deliberately dropped (see the deck's width gate),
  // which is exactly the narrow case worth exercising by default.
  Widget app(Widget child) => MaterialApp(
        theme: rewindTheme(),
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 220, child: child))),
      );

  // The controls live in a popover now (see RecorderButton's doc: the window
  // carries no permanent recorder chrome, because while you're gaming the
  // window is behind the game). Everything except the chip itself needs the
  // panel opened first.
  Future<void> openPanel(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('recorderButton')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  // The deck runs a 1 s ticker whenever a recording is live or the buffer
  // ring is still filling, so `pumpAndSettle` can wait for a frame that is
  // never the last one. Bounded pumps step through the popup menu's (finite)
  // open/close transition instead.
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

  RecorderButton deck({
    required AppSettings settings,
    List<DisplayInfo> displays = _displays,
    List<AppInfo> capturableApps = const [],
    String? captureError,
    Future<void> Function(AppSettings)? onSettingsChanged,
    ValueListenable<int>? settingsRevision,
    // Lets a test grab the coordinator before pumping, to set activeGame /
    // autoSwitchedAppName ahead of time.
    ClipCoordinator? coordinatorOverride,
    ValueListenable<bool>? bufferActive,
    ValueListenable<bool>? bufferAutoPaused,
  }) =>
      RecorderButton(
        coordinator: coordinatorOverride ?? makeCoordinator(settings),
        hotkeyLabel: 'F9',
        captureError: captureError,
        bufferActive: bufferActive,
        bufferAutoPaused: bufferAutoPaused,
        displays: displays,
        capturableApps: capturableApps,
        onSettingsChanged: onSettingsChanged ?? (_) async {},
        onOpenSettings: () {},
        settingsRevision: settingsRevision,
      );

  group('capture-source line', () {
    testWidgets('shows the current source: main display by default', (t) async {
      await t.pumpWidget(app(deck(settings: AppSettings())));
      await openPanel(t);
      expect(sourceLine('Display 1'), findsOneWidget);
    });

    testWidgets('the panel reads source -> buffer -> actions, top to bottom',
        (t) async {
      // The picker decides what the buttons capture, so it must precede them.
      await t.pumpWidget(app(deck(settings: AppSettings())));
      await openPanel(t);
      final source =
          t.getTopLeft(find.byKey(const ValueKey('recorderSourceLine'))).dy;
      final buffer =
          t.getTopLeft(find.byKey(const ValueKey('deckBufferReadout'))).dy;
      final save = t.getTopLeft(find.byKey(const ValueKey('deckSaveClip'))).dy;
      final record =
          t.getTopLeft(find.byKey(const ValueKey('recordButton'))).dy;
      expect(source, lessThan(buffer));
      expect(buffer, lessThan(save));
      expect(save, lessThan(record));
    });

    testWidgets('shows the app name when an app target is set', (t) async {
      await t.pumpWidget(app(deck(
        settings: AppSettings(captureAppBundleId: 'com.example.two'),
        capturableApps: _apps,
      )));
      await openPanel(t);
      expect(sourceLine('App Two'), findsOneWidget);
    });

    testWidgets('hidden only when nothing at all is pickable', (t) async {
      // No displays AND no apps AND no live enumerator — the degenerate
      // "capture is impossible" case is the only one that hides the line.
      await t
          .pumpWidget(app(deck(settings: AppSettings(), displays: const [])));
      await openPanel(t);
      expect(find.byIcon(Icons.desktop_windows_outlined), findsNothing);
      expect(find.byIcon(Icons.apps_outlined), findsNothing);
    });

    testWidgets(
        'still shown when apps are pickable but displays came back '
        'empty (the empty-displays-at-startup case)', (t) async {
      // A single empty listDisplays() at launch must NOT hide the only
      // app-picker in the main window: apps enumerated fine, so the game is
      // still pickable here even though no display was reported.
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        displays: const [],
        capturableApps: _apps,
      )));
      await openPanel(t);
      expect(find.byKey(const ValueKey('recorderSourceLine')), findsOneWidget);
    });

    testWidgets(
        'picking an app updates settings.captureAppBundleId and '
        'fires onSettingsChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: const [..._apps, catalogApp],
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: const [..._apps, iconApp],
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: const [crossover, wineGame],
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: const [..._apps, league],
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: AppSettings(
          captureAppBundleId: 'com.codeweavers.CrossOver',
          captureAppName: 'PenguinHotel-Win64-Shipping',
        ),
        capturableApps: const [crossover, wineGame],
      )));
      await openPanel(t);
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
      await t.pumpWidget(app(deck(
        settings: settings,
        coordinatorOverride: coordinator,
        capturableApps: [..._apps, wineGame],
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: _apps,
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(RecorderButton(
        coordinator: makeCoordinator(AppSettings()),
        hotkeyLabel: 'F9',
        displays: _displays,
        capturableApps: [_apps[0]],
        listApps: () => [_apps[0], lateGame],
        onSettingsChanged: (_) async {},
        onOpenSettings: () {},
      )));
      await openPanel(t);

      await t.tap(sourceLine('Display 1'));
      await settleMenu(t);
      expect(find.text('PenguinHotel-Win64-Shipping'), findsOneWidget);
    });

    testWidgets(
        'picking a display writes captureDisplayUuid and clears '
        'captureAppBundleId', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(captureAppBundleId: 'com.example.one');
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

      expect(find.text('00:00 / 00:30'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('deckBufferReadout')));
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
      await t.pumpWidget(app(deck(
        settings: settings,
        coordinatorOverride: coordinator,
        onSettingsChanged: (s) async => calls.add(s),
      )));
      await openPanel(t);

      expect(find.text('00:00 / 00:30'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('deckBufferReadout')));
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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: _apps,
        settingsRevision: revision,
        onSettingsChanged: (s) async => revision.value++,
      )));
      await openPanel(t);

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
      await t.pumpWidget(app(deck(
        settings: settings,
        settingsRevision: revision,
        onSettingsChanged: (s) async => revision.value++,
      )));
      await openPanel(t);

      expect(find.text('00:00 / 00:30'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('deckBufferReadout')));
      await settleMenu(t);
      await t.tap(find.text('60 s').last);
      await settleMenu(t);

      expect(find.text('00:00 / 01:00'), findsOneWidget);
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
      await t.pumpWidget(app(deck(
        settings: settings,
        capturableApps: _apps,
        coordinatorOverride: coordinator,
      )));
      await openPanel(t);

      expect(find.text('Stub App One (auto)'), findsOneWidget);
      // Exact match: the persisted "App One" is a substring of the
      // auto-switched label, so this only proves the *plain* (non-auto)
      // label isn't also rendered somewhere.
      expect(find.text('App One'), findsNothing);
    });
  });

  group('tally light', () {
    testWidgets('reads PAUSED when stopped with no auto-pause signal',
        (t) async {
      final active = ValueNotifier<bool>(false);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        bufferActive: active,
      )));
      await openPanel(t);
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('WAITING'), findsNothing);
    });

    testWidgets(
        'reads WAITING FOR A GAME when stopped and bufferAutoPaused is '
        'true (the captureOnlyInGame policy, not a manual pause)', (t) async {
      final active = ValueNotifier<bool>(false);
      final autoPaused = ValueNotifier<bool>(true);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        bufferActive: active,
        bufferAutoPaused: autoPaused,
      )));
      await openPanel(t);
      expect(find.text('WAITING'), findsOneWidget);
      expect(find.text('PAUSED'), findsNothing);
    });

    testWidgets('flipping bufferAutoPaused live updates the tally', (t) async {
      final active = ValueNotifier<bool>(false);
      final autoPaused = ValueNotifier<bool>(false);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        bufferActive: active,
        bufferAutoPaused: autoPaused,
      )));
      await openPanel(t);
      expect(find.text('PAUSED'), findsOneWidget);

      autoPaused.value = true;
      await t.pump();
      expect(find.text('WAITING'), findsOneWidget);
      expect(find.text('PAUSED'), findsNothing);
    });

    testWidgets('UNAVAILABLE wins over every other state', (t) async {
      final active = ValueNotifier<bool>(false);
      final autoPaused = ValueNotifier<bool>(true);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        captureError: 'boom',
        bufferActive: active,
        bufferAutoPaused: autoPaused,
      )));
      await openPanel(t);
      expect(find.text('UNAVAILABLE'), findsOneWidget);
      expect(find.text('WAITING'), findsNothing);
    });

    testWidgets('a running buffer reads ARMED', (t) async {
      final active = ValueNotifier<bool>(true);
      final autoPaused = ValueNotifier<bool>(false);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        bufferActive: active,
        bufferAutoPaused: autoPaused,
      )));
      await openPanel(t);
      expect(find.text('ARMED'), findsOneWidget);
      expect(find.text('WAITING'), findsNothing);
      expect(find.text('PAUSED'), findsNothing);
    });

    testWidgets('every tally state carries a spoken label, not colour alone',
        (t) async {
      // The dot conveys state by colour; without this the whole signal is
      // invisible to a screen reader (audit F-07).
      final handle = t.ensureSemantics();
      final active = ValueNotifier<bool>(true);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        bufferActive: active,
      )));
      expect(find.bySemanticsLabel(RegExp(r'^Armed — holding the last')),
          findsOneWidget);

      active.value = false;
      await t.pump();
      expect(find.bySemanticsLabel('Paused — the replay buffer is stopped'),
          findsOneWidget);
      handle.dispose();
    });
  });

  group('buffer ring', () {
    testWidgets('a just-started buffer is not yet full, and fills over time',
        (t) async {
      // "ARMED" alone overstates a buffer that has only held four seconds:
      // a save right now reaches back four seconds, not thirty.
      final active = ValueNotifier<bool>(true);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        bufferActive: active,
      )));
      await openPanel(t);
      // The fill is reported in words + a bar in the panel, and ONLY while
      // it is still filling — a ring sitting at zero read as "off" rather
      // than "filling".
      double fill() => t.widget<BufferFill>(find.byType(BufferFill)).fill;
      expect(find.text('00:00 / 00:30'), findsOneWidget);
      expect(fill(), 0);

      await t.pump(const Duration(seconds: 15));
      expect(fill(), closeTo(0.5, 0.05));

      await t.pump(const Duration(seconds: 15));
      // Full: the line removes itself rather than sitting at 100%.
      expect(find.byType(BufferFill), findsNothing);
    });

    testWidgets('the fill ticker stops once the buffer is full', (t) async {
      // A recorder must not keep the UI repainting while you game — see
      // `_TransportDeckState._ticker`. `pump` throwing on a pending timer is
      // what would catch a regression here, so simply reaching the end of
      // the test with no pending-timer failure is the assertion.
      final active = ValueNotifier<bool>(true);
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        bufferActive: active,
      )));
      await openPanel(t);
      await t.pump(const Duration(seconds: 31));
      expect(find.byType(BufferFill), findsNothing);
    });
  });

  group('record button', () {
    testWidgets('idle state shows an outlined "Record" button', (t) async {
      await t.pumpWidget(app(deck(settings: AppSettings())));
      await openPanel(t);
      expect(find.text('Record'), findsOneWidget);
      final btn =
          t.widget<OutlinedButton>(find.byKey(const ValueKey('recordButton')));
      expect(btn.onPressed, isNotNull);
    });

    testWidgets(
        'tapping starts a recording, flipping to the filled elapsed state',
        (t) async {
      final coordinator = makeCoordinator(AppSettings());
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        coordinatorOverride: coordinator,
      )));
      await openPanel(t);

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();

      expect(coordinator.isRecording.value, isTrue);
      expect(find.text('Record'), findsNothing);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('recordButton')),
              matching: find.text('0:00')),
          findsOneWidget);
      // The tally reports it too, so the state is legible from the far left
      // of the deck without reading the button.
      expect(find.text('REC 0:00'), findsOneWidget);

      // Stop before the test ends so no Timer is left pending (bounded
      // pumps only — see the file's pumpAndSettle caveat).
      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.pump();
    });

    testWidgets('the elapsed readout ticks once a second while recording',
        (t) async {
      final coordinator = makeCoordinator(AppSettings());
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        coordinatorOverride: coordinator,
      )));
      await openPanel(t);

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      Finder elapsed(String v) => find.descendant(
          of: find.byKey(const ValueKey('recordButton')),
          matching: find.text(v));
      expect(elapsed('0:00'), findsOneWidget);

      await t.pump(const Duration(seconds: 1));
      expect(elapsed('0:01'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.pump();
    });

    testWidgets(
        'tapping again while recording stops it and saves a recording clip',
        (t) async {
      final coordinator = makeCoordinator(AppSettings());
      await t.pumpWidget(app(deck(
        settings: AppSettings(),
        coordinatorOverride: coordinator,
      )));
      await openPanel(t);

      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('recordButton')));
      await t.pump();
      await t.pump(); // let the async stop/save chain settle

      expect(coordinator.isRecording.value, isFalse);
      expect(find.text('Record'), findsOneWidget);
    });

    testWidgets('disabled when there is a capture error', (t) async {
      await t
          .pumpWidget(app(deck(settings: AppSettings(), captureError: 'boom')));
      await openPanel(t);
      final btn =
          t.widget<OutlinedButton>(find.byKey(const ValueKey('recordButton')));
      expect(btn.onPressed, isNull);
    });
  });
}
