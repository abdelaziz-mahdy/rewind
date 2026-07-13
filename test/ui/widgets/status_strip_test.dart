import 'dart:io';

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
import 'package:rewind/src/ui/widgets/status_strip.dart';

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
    tmp = Directory.systemTemp.createTempSync('rewind_status_strip');
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

  Widget app(Widget child) => MaterialApp(
        theme: rewindTheme(),
        home: Scaffold(body: child),
      );

  // The status strip's pulsing "recording" dot runs an
  // AnimationController.repeat() that never settles on its own — unlike
  // pushing a full route (which pauses tickers behind it via TickerMode),
  // a popup menu doesn't stop it — so `pumpAndSettle` would hang forever
  // waiting for a frame that's never the last one. Bounded pumps step
  // through the popup menu's (finite) open/close transition instead.
  Future<void> settleMenu(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  StatusStrip strip({
    required AppSettings settings,
    List<DisplayInfo> displays = _displays,
    List<AppInfo> capturableApps = const [],
    String? captureError,
    Future<void> Function(AppSettings)? onSettingsChanged,
  }) =>
      StatusStrip(
        coordinator: makeCoordinator(settings),
        captureError: captureError,
        displays: displays,
        capturableApps: capturableApps,
        onSettingsChanged: onSettingsChanged ?? (_) async {},
        onOpenSettings: () {},
      );

  group('capture-source chip', () {
    testWidgets('shows the current source: main display by default', (t) async {
      await t.pumpWidget(app(strip(settings: AppSettings())));
      expect(find.textContaining('Capturing: Display 1'), findsOneWidget);
    });

    testWidgets('shows the app name when an app target is set', (t) async {
      await t.pumpWidget(app(strip(
        settings: AppSettings(captureAppBundleId: 'com.example.two'),
        capturableApps: _apps,
      )));
      expect(find.textContaining('Capturing: App Two'), findsOneWidget);
    });

    testWidgets('hidden entirely when there are no displays to pick between',
        (t) async {
      await t
          .pumpWidget(app(strip(settings: AppSettings(), displays: const [])));
      expect(find.textContaining('Capturing:'), findsNothing);
    });

    testWidgets(
        'picking an app updates settings.captureAppBundleId and '
        'fires onSettingsChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(app(strip(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(find.textContaining('Capturing: Display 1'));
      await settleMenu(t);
      await t.tap(find.text('App Two').last);
      await settleMenu(t);

      expect(calls, isNotEmpty);
      expect(calls.last.captureAppBundleId, 'com.example.two');
    });

    testWidgets(
        'picking a display writes captureDisplayUuid and clears '
        'captureAppBundleId', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(captureAppBundleId: 'com.example.one');
      await t.pumpWidget(app(strip(
        settings: settings,
        capturableApps: _apps,
        onSettingsChanged: (s) async => calls.add(s),
      )));

      await t.tap(find.textContaining('Capturing: App One'));
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
      await t.pumpWidget(app(strip(
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
  });

  group('permission banner button', () {
    testWidgets('present for a permission-related capture error', (t) async {
      await t.pumpWidget(app(strip(
        settings: AppSettings(),
        captureError: 'Screen recording permission denied',
      )));
      expect(
        find.text('Open Screen Recording Settings'),
        Platform.isMacOS ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('absent for a non-permission capture error', (t) async {
      await t.pumpWidget(app(strip(
        settings: AppSettings(),
        captureError: 'libobs init failed',
      )));
      expect(find.text('Open Screen Recording Settings'), findsNothing);
    });
  });
}
