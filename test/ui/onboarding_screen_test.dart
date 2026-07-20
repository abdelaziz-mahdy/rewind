import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/onboarding_screen.dart';
import 'package:rewind/src/ui/theme.dart';

import '../fakes/fake_capture_engine.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

void main() {
  OnboardingScreen screen({
    AppSettings? settings,
    Future<void> Function(AppSettings)? onChanged,
    VoidCallback? onDone,
    Future<void> Function()? onOpenScreenRecording,
    FakeCaptureEngine? engine,
    ClipLibrary? library,
    String? captureError,
    VoidCallback? onRelaunch,
    List<AppInfo> Function()? listApps,
    VoidCallback? onSetUpSteam,
  }) =>
      OnboardingScreen(
        settings: settings ?? AppSettings(),
        onChanged: onChanged ?? (_) async {},
        onDone: onDone ?? () {},
        onOpenScreenRecording: onOpenScreenRecording,
        engine: engine,
        library: library,
        captureError: captureError,
        onRelaunch: onRelaunch,
        listApps: listApps,
        onSetUpSteam: onSetUpSteam,
      );

  Future<void> nextTo(WidgetTester t, int steps) async {
    for (var i = 0; i < steps; i++) {
      await t.tap(find.byKey(const ValueKey('onboardingNext')));
      await t.pumpAndSettle();
    }
  }

  testWidgets('opens on the welcome step', (t) async {
    await t.pumpWidget(_app(screen()));
    expect(find.text('Never miss a play'), findsOneWidget);
  });

  testWidgets(
      'permission step: granted at launch shows the compact tick '
      'with no buttons', (t) async {
    final engine = FakeCaptureEngine()..screenPermissionGranted = true;
    await t.pumpWidget(_app(screen(engine: engine)));
    await nextTo(t, 1);
    expect(
        find.text("Screen Recording is granted — you're set."), findsOneWidget);
    expect(find.byKey(const ValueKey('grantScreenPermissionButton')),
        findsNothing);
    expect(find.byKey(const ValueKey('relaunchButton')), findsNothing);
  });

  testWidgets('permission step: not granted shows Grant + Open Settings',
      (t) async {
    final engine = FakeCaptureEngine()..screenPermissionGranted = false;
    await t.pumpWidget(_app(screen(engine: engine)));
    await nextTo(t, 1);
    expect(find.byKey(const ValueKey('grantScreenPermissionButton')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('openScreenSettingsButton')), findsOneWidget);
  });

  testWidgets('permission step: granted mid-session shows the relaunch state',
      (t) async {
    final engine = FakeCaptureEngine()..screenPermissionGranted = true;
    await t.pumpWidget(_app(screen(
        engine: engine,
        captureError: 'replay buffer failed to start',
        onRelaunch: () {})));
    await nextTo(t, 1);
    expect(find.text('Granted. Relaunch Rewind to start capturing.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('relaunchButton')), findsOneWidget);
  });

  testWidgets(
      'permission step: relaunch state without a relaunch hook shows the '
      'quit-and-reopen instruction instead of a dead button', (t) async {
    final engine = FakeCaptureEngine()..screenPermissionGranted = true;
    await t.pumpWidget(_app(
        screen(engine: engine, captureError: 'replay buffer failed to start')));
    await nextTo(t, 1);
    expect(find.byKey(const ValueKey('relaunchButton')), findsNothing);
    expect(find.text('Quit and reopen Rewind to start capturing.'),
        findsOneWidget);
  });

  testWidgets('permission step opens System Settings via the secondary button',
      (t) async {
    var opened = 0;
    final engine = FakeCaptureEngine()..screenPermissionGranted = false;
    await t.pumpWidget(_app(screen(
      engine: engine,
      onOpenScreenRecording: () async => opened++,
    )));
    await nextTo(t, 1);
    await t.tap(find.byKey(const ValueKey('openScreenSettingsButton')));
    await t.pump();
    expect(opened, 1);
  });

  testWidgets('permission step: Grant button calls requestScreenPermission',
      (t) async {
    final engine = FakeCaptureEngine()..screenPermissionGranted = false;
    await t.pumpWidget(_app(screen(engine: engine)));
    await nextTo(t, 1);
    await t.tap(find.byKey(const ValueKey('grantScreenPermissionButton')));
    await t.pump();
    expect(engine.calls, contains('requestScreenPermission'));
  });

  testWidgets(
      'permission step: polling flips the UI live when the fake grants '
      'mid-visit', (t) async {
    final engine = FakeCaptureEngine()..screenPermissionGranted = false;
    await t.pumpWidget(_app(screen(engine: engine)));
    await nextTo(t, 1);
    expect(find.byKey(const ValueKey('grantScreenPermissionButton')),
        findsOneWidget);

    engine.screenPermissionGranted = true;
    await t.pump(const Duration(seconds: 1));
    await t.pump();

    expect(
        find.text("Screen Recording is granted — you're set."), findsOneWidget);
    expect(find.byKey(const ValueKey('grantScreenPermissionButton')),
        findsNothing);
  });

  testWidgets(
      'permission step: relaunch button fires the injected callback, '
      'never a real relaunch', (t) async {
    var relaunches = 0;
    final engine = FakeCaptureEngine()..screenPermissionGranted = true;
    await t.pumpWidget(_app(screen(
      engine: engine,
      captureError: 'replay buffer failed to start',
      onRelaunch: () => relaunches++,
    )));
    await nextTo(t, 1);
    await t.tap(find.byKey(const ValueKey('relaunchButton')));
    await t.pump();
    expect(relaunches, 1);
  });

  testWidgets('the buffer step writes the chosen length and persists',
      (t) async {
    final settings = AppSettings();
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(screen(
      settings: settings,
      onChanged: (s) async => calls.add(s),
    )));
    await nextTo(t, 2); // welcome -> permission -> buffer

    await t.tap(find.text('60 s'));
    await t.pump();
    expect(settings.defaultBufferSeconds, 60);
    expect(calls, isNotEmpty);
  });

  testWidgets('the preferences step toggles mic and follow-the-game',
      (t) async {
    final settings = AppSettings(); // mic off, autoSwitch on by default
    await t.pumpWidget(_app(screen(settings: settings)));
    await nextTo(t, 3); // -> preferences

    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(2));
    await t.tap(switches.first); // Capture microphone
    await t.pump();
    expect(settings.captureMicrophone, isTrue);

    await t.tap(switches.last); // Follow the game -> off
    await t.pump();
    expect(settings.autoSwitchCapture, isFalse);
  });

  testWidgets(
      'the games step shows a line when a running app matches a catalog '
      'game', (t) async {
    await t.pumpWidget(_app(screen(
      listApps: () => const [
        AppInfo(bundleId: 'com.test.cs2', name: 'CS2', pid: 42),
      ],
    )));
    await nextTo(t, 4); // -> controls & games
    expect(
        find.textContaining(
            'We can see Counter-Strike 2 running — its highlights will '
            'clip automatically.'),
        findsOneWidget);
  });

  testWidgets('the games step shows no extra line when nothing matches',
      (t) async {
    await t.pumpWidget(_app(screen(listApps: () => const [])));
    await nextTo(t, 4); // -> controls & games
    expect(find.textContaining('We can see'), findsNothing);
  });

  testWidgets('the games step pitches Steam achievement clipping', (t) async {
    await t.pumpWidget(_app(screen()));
    await nextTo(t, 4); // -> controls & games
    expect(
        find.textContaining('Any Steam game: unlocking an achievement '
            'saves a clip labeled with its name.'),
        findsOneWidget);
  });

  testWidgets(
      'the games step hides the Steam setup button when onSetUpSteam is null',
      (t) async {
    await t.pumpWidget(_app(screen()));
    await nextTo(t, 4); // -> controls & games
    expect(find.byKey(const ValueKey('steamSetupButton')), findsNothing);
  });

  testWidgets(
      'the games step shows a Steam setup button that invokes onSetUpSteam',
      (t) async {
    var calls = 0;
    await t.pumpWidget(_app(screen(onSetUpSteam: () => calls++)));
    await nextTo(t, 4); // -> controls & games
    final button = find.byKey(const ValueKey('steamSetupButton'));
    expect(button, findsOneWidget);
    await t.ensureVisible(button);
    await t.pump();
    await t.tap(button);
    expect(calls, 1);
  });

  testWidgets(
      'the try-it step flips to success when a clip lands in the library '
      'while visible', (t) async {
    final library = ClipLibrary(clipsDir: Directory.systemTemp);
    await t.pumpWidget(_app(screen(library: library)));
    await nextTo(
        t, 5); // welcome/permission/buffer/preferences/controls -> try it
    expect(find.text('Try it now'), findsOneWidget);
    expect(find.byKey(const ValueKey('tryItSuccess')), findsNothing);

    library.add(Clip(
      path: '/tmp/clip.mp4',
      gameId: 'desktop',
      event: GameEventKind.manual,
      createdAt: DateTime.now(),
      sizeBytes: 2 * 1024 * 1024,
    ));
    await t.pump();

    expect(find.byKey(const ValueKey('tryItSuccess')), findsOneWidget);
    expect(find.text('Clip saved!'), findsOneWidget);
  });

  testWidgets(
      'a degraded capture (captureError set) falls back to the plain '
      'controls step as the last page — no try-it step', (t) async {
    var done = 0;
    await t.pumpWidget(_app(screen(
      onDone: () => done++,
      captureError: 'replay buffer failed to start',
    )));
    await nextTo(
        t, 4); // welcome/permission/buffer/preferences -> controls&games
    expect(find.widgetWithText(FilledButton, 'Get started'), findsOneWidget);
    expect(find.text('Try it now'), findsNothing);
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    expect(done, 1);
  });

  testWidgets('the last step (try it now) finishes via Get started', (t) async {
    var done = 0;
    await t.pumpWidget(_app(screen(onDone: () => done++)));
    await nextTo(t, 5); // to the final (try-it) step
    expect(find.text('Try it now'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Get started'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    expect(done, 1);
  });

  testWidgets('the try-it step teaches the new "only while playing" default',
      (t) async {
    await t.pumpWidget(_app(screen()));
    await nextTo(t, 5); // -> try it
    expect(find.textContaining("Rewind records only while you're playing"),
        findsOneWidget);
    expect(find.textContaining('Only record while playing'), findsOneWidget);
  });

  testWidgets('Skip invokes onDone immediately', (t) async {
    var done = 0;
    await t.pumpWidget(_app(screen(onDone: () => done++)));
    await t.tap(find.byKey(const ValueKey('onboardingSkip')));
    expect(done, 1);
  });
}
