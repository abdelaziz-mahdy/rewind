import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/obs/audio_input_info.dart';
import 'package:rewind/src/obs/display_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/settings_screen.dart';
import 'package:rewind/src/ui/system_settings.dart';
import 'package:rewind/src/ui/theme.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

/// Taps the SAVE hotkey recorder field, putting it into "Press keys…" state.
/// Targeted by key rather than by displayed text: with the record hotkey
/// field also on screen (default "Alt+F9"), a text-based finder would match
/// both fields.
Future<void> _startRecording(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('saveHotkeyField')));
  await t.pump();
}

/// Switches to the given sidebar page ("Capture", "Hotkey", "Storage",
/// "About" — the id, not necessarily the displayed label; "Hotkey"'s label
/// is "Hotkeys"). Only the selected page's content is built — every test
/// reaching into a non-default page must call this first.
Future<void> openPage(WidgetTester t, String id) async {
  await t.tap(find.byKey(ValueKey('settingsTab:$id')));
  await t.pump();
}

/// Opens the Capture page's single "› Advanced options" disclosure (Capture
/// display / Capture application / Follow the game all live there now).
Future<void> openAdvanced(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('advancedOptionsToggle')));
  await t.pumpAndSettle();
}

void main() {
  // The Capture page (Instant replay, the 2x2 preset grid, Audio, and the
  // Advanced disclosure) is tall enough that the default 800x600 test
  // viewport pushes "› Advanced options" — and everything a test opens
  // inside it — below the visible area: `tap()` finds the widget in the
  // tree but can't hit-test an offset outside the viewport's own bounds.
  // Same fix as `shell_test.dart`'s `_pumpTall`: widen the viewport for
  // every test in this file rather than threading `ensureVisible()` through
  // each one.
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

  testWidgets(
      'recording a NEW combo updates settings, fires onChanged, AND the '
      'field immediately shows the new combo', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    await openPage(t, 'Hotkey');
    await _startRecording(t);
    expect(find.text('Press keys…'), findsOneWidget);

    // Ctrl+7 — deliberately DIFFERENT from the Alt+F10 default. The old
    // version of this test captured Alt+F10 itself, so a stale display
    // (still showing the previous value) was indistinguishable from a
    // fresh one — which masked a real bug: the field kept showing the old
    // combo after a successful capture because the parent never rebuilt.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.digit7);
    await t.pump();

    expect(calls, isNotEmpty);
    expect(calls.last.hotkey, 'Ctrl+7');
    expect(find.text('Ctrl+7'), findsOneWidget);
    expect(find.text('Alt+F10'), findsNothing,
        reason: 'the field must show the NEW combo, not the stale one');

    await t.sendKeyUpEvent(LogicalKeyboardKey.digit7);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets(
      'bare letter without a modifier is rejected and settings unchanged',
      (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    await openPage(t, 'Hotkey');
    await _startRecording(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await t.pump();

    expect(calls, isEmpty);
    // Still listening — the hint is shown and the field didn't close.
    expect(find.text('Press keys…'), findsOneWidget);
    expect(find.textContaining('modifier'), findsOneWidget);

    await t.sendKeyUpEvent(LogicalKeyboardKey.keyS);
  });

  testWidgets('Escape cancels recording, leaving the prior value', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    await openPage(t, 'Hotkey');
    await _startRecording(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await t.pump();

    expect(calls, isEmpty);
    expect(find.text('Press keys…'), findsNothing);
    expect(find.text('Alt+F10'), findsOneWidget); // AppSettings() default

    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
  });

  testWidgets('a bare F-key is accepted with no modifier needed', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    await openPage(t, 'Hotkey');
    await _startRecording(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.f9);
    await t.pump();

    expect(calls, isNotEmpty);
    expect(calls.last.hotkey, 'F9');

    await t.sendKeyUpEvent(LogicalKeyboardKey.f9);
  });

  testWidgets(
      'onHotkeyRecording fires true on start, false on Escape-cancel, and '
      'is NOT re-fired on a successful capture (onChanged owns that rebind)',
      (t) async {
    final calls = <AppSettings>[];
    final recording = <bool>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
      onHotkeyRecording: (r) async => recording.add(r),
    )));

    await openPage(t, 'Hotkey');
    // Start listening, then cancel with Escape.
    await _startRecording(t);
    expect(recording, [true]);

    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    expect(recording, [true, false]);

    // Start listening again, this time capture a combo successfully.
    await _startRecording(t);
    expect(recording, [true, false, true]);

    await t.sendKeyDownEvent(LogicalKeyboardKey.f9);
    await t.pump();
    await t.sendKeyUpEvent(LogicalKeyboardKey.f9);

    // The capture path fires onChanged (whose handler rebinds the NEW
    // hotkey) and deliberately does NOT also fire onRecording(false):
    // two concurrent unregisterAll+register cycles can interleave into a
    // double registration, making one press save two clips.
    expect(recording, [true, false, true]);
    expect(calls, isNotEmpty);
    expect(calls.last.hotkey, 'F9');
  });

  testWidgets('the record hotkey field shows its own default value', (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
    )));

    await openPage(t, 'Hotkey');
    expect(find.text('Alt+F10'), findsOneWidget); // save hotkey
    expect(find.text('Alt+F9'), findsOneWidget); // record hotkey
  });

  testWidgets(
      'recording a combo in the record hotkey field updates '
      'settings.recordHotkey without touching settings.hotkey', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    await openPage(t, 'Hotkey');
    await t.tap(find.byKey(const ValueKey('recordHotkeyField')));
    await t.pump();
    expect(find.text('Press keys…'), findsOneWidget);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.f8);
    await t.pump();

    expect(calls, isNotEmpty);
    expect(calls.last.recordHotkey, 'Ctrl+F8');
    expect(calls.last.hotkey, 'Alt+F10'); // untouched

    await t.sendKeyUpEvent(LogicalKeyboardKey.f8);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets(
      'onHotkeyRecording fires for the record field too, same as the '
      'save field', (t) async {
    final recording = <bool>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      onHotkeyRecording: (r) async => recording.add(r),
    )));

    await openPage(t, 'Hotkey');
    await t.tap(find.byKey(const ValueKey('recordHotkeyField')));
    await t.pump();
    expect(recording, [true]);

    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    expect(recording, [true, false]);
  });

  testWidgets('picking 60s updates settings via onChanged', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    await t.tap(find.text('60 s'));
    await t.pump();

    expect(calls, isNotEmpty);
    expect(calls.last.defaultBufferSeconds, 60);
  });

  testWidgets('custom buffer clamps to 5..300', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    // "Custom" also labels the Video section's Custom preset card further
    // down the same page — .first is the Instant replay segment, earlier
    // in the tree.
    await t.tap(find.text('Custom').first);
    await t.pump();

    final field = find.widgetWithText(TextField, 'Seconds (5-300)');
    expect(field, findsOneWidget);

    await t.enterText(field, '999');
    await t.pump();
    expect(calls.last.defaultBufferSeconds, 300);

    await t.enterText(field, '1');
    await t.pump();
    expect(calls.last.defaultBufferSeconds, 5);
  });

  testWidgets('no displays hides the Capture display row', (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
    )));

    await openAdvanced(t);
    expect(find.textContaining('Capture display'), findsNothing);
  });

  const displays = [
    DisplayInfo(uuid: 'uuid-1', width: 1920, height: 1080, isMain: true),
    DisplayInfo(uuid: 'uuid-2', width: 2560, height: 1440, isMain: false),
  ];

  testWidgets('capture display row lists displays, main pre-selected',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: displays,
    )));

    await openAdvanced(t);
    expect(find.textContaining('Capture display'), findsOneWidget);
    expect(find.text('Display 1 — 1920×1080 (Main)'), findsOneWidget);
  });

  testWidgets(
      'picking the second display updates settings and fires '
      'onChanged', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: displays,
    )));

    await openAdvanced(t);
    await t.tap(find.text('Display 1 — 1920×1080 (Main)'));
    await t.pumpAndSettle();
    await t.tap(find.text('Display 2 — 2560×1440').last);
    await t.pumpAndSettle();

    expect(calls, isNotEmpty);
    expect(calls.last.captureDisplayUuid, 'uuid-2');
  });

  const apps = [
    AppInfo(bundleId: 'com.example.one', name: 'App One', pid: 1),
    AppInfo(bundleId: 'com.example.two', name: 'App Two', pid: 2),
  ];

  testWidgets('no capturable apps hides the Capture application row',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      capturableApps: const [],
    )));

    await openAdvanced(t);
    expect(find.textContaining('Capture application'), findsNothing);
  });

  testWidgets(
      'capture application row lists apps plus "Entire display", '
      'defaulting to "Entire display"', (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      capturableApps: apps,
    )));

    await openAdvanced(t);
    expect(find.textContaining('Capture application'), findsOneWidget);
    expect(find.text('Entire display'), findsOneWidget);
  });

  testWidgets(
      'picking an app updates settings.captureAppBundleId and '
      'fires onChanged', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
      capturableApps: apps,
    )));

    await openAdvanced(t);
    await t.tap(find.text('Entire display'));
    await t.pumpAndSettle();
    await t.tap(find.text('App Two').last);
    await t.pumpAndSettle();

    expect(calls, isNotEmpty);
    expect(calls.last.captureAppBundleId, 'com.example.two');
  });

  testWidgets('picking "Entire display" reverts captureAppBundleId to null',
      (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(captureAppBundleId: 'com.example.one'),
      onChanged: (s) async => calls.add(s),
      displays: const [],
      capturableApps: apps,
    )));

    await openAdvanced(t);
    expect(find.text('App One'), findsOneWidget);

    await t.tap(find.text('App One'));
    await t.pumpAndSettle();
    await t.tap(find.text('Entire display').last);
    await t.pumpAndSettle();

    expect(calls, isNotEmpty);
    expect(calls.last.captureAppBundleId, isNull);
  });

  testWidgets(
      'a saved bundle id not in capturableApps shows as "Entire display" '
      'without touching the persisted setting', (t) async {
    final settings = AppSettings(captureAppBundleId: 'com.example.stale');
    await t.pumpWidget(_app(SettingsScreen(
      settings: settings,
      onChanged: (_) async {},
      displays: const [],
      capturableApps: apps,
    )));

    await openAdvanced(t);
    expect(find.text('Entire display'), findsOneWidget);
    expect(settings.captureAppBundleId, 'com.example.stale');
  });

  group('Only record while playing', () {
    testWidgets('defaults on and toggling writes captureOnlyInGame', (t) async {
      final calls = <AppSettings>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      expect(
          t
              .widget<Switch>(find.byKey(const ValueKey('onlyInGameSwitch')))
              .value,
          isTrue);

      await t.tap(find.byKey(const ValueKey('onlyInGameSwitch')));
      await t.pump();

      expect(calls, isNotEmpty);
      expect(calls.last.captureOnlyInGame, isFalse);
      expect(
          t
              .widget<Switch>(find.byKey(const ValueKey('onlyInGameSwitch')))
              .value,
          isFalse);
    });

    testWidgets('shows the CPU/battery hint', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(
          find.text('Pause the replay buffer when no game is detected — '
              'saves CPU and battery at the desktop.'),
          findsOneWidget);
    });
  });

  testWidgets(
      'the MY GAMES section is not built yet — per-game settings still '
      'live in each game\'s hub', (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
    )));

    expect(find.textContaining('Per-game'), findsNothing);
    expect(find.textContaining('MY GAMES'), findsNothing);
  });

  group('Advanced options disclosure', () {
    testWidgets('starts closed and reveals Follow the game on tap', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(autoSwitchCapture: false),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(find.text('Follow the game'), findsNothing);
      await openAdvanced(t);
      expect(find.text('Follow the game'), findsOneWidget);
    });

    testWidgets('tapping again collapses it', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      await openAdvanced(t);
      expect(find.text('Follow the game'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('advancedOptionsToggle')));
      await t.pumpAndSettle();
      expect(find.text('Follow the game'), findsNothing);
    });

    testWidgets(
        'toggling follow-the-game writes autoSwitchCapture and fires '
        'onChanged', (t) async {
      final calls = <AppSettings>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await openAdvanced(t);
      expect(
          t
              .widget<Switch>(
                  find.byKey(const ValueKey('autoSwitchCaptureSwitch')))
              .value,
          isTrue);

      await t.tap(find.byKey(const ValueKey('autoSwitchCaptureSwitch')));
      await t.pump();

      expect(calls, isNotEmpty);
      expect(calls.last.autoSwitchCapture, isFalse);
      expect(
          t
              .widget<Switch>(
                  find.byKey(const ValueKey('autoSwitchCaptureSwitch')))
              .value,
          isFalse);
    });
  });

  group('Video presets', () {
    testWidgets('Balanced (default fps 60 / maxHeight 1080) shows selected',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      // The Performance card's own outcome line is unique to it — proves
      // all four preset cards actually rendered.
      expect(
          find.textContaining(
              'Lightest on your system and disk — great for quick moments.'),
          findsOneWidget);
      expect(find.text('RECOMMENDED'), findsOneWidget);
    });

    testWidgets(
        'tapping a named preset card writes fps/maxHeight and '
        'fires onChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await t.tap(find.byKey(const ValueKey('videoPreset:high')));
      await t.pump();

      expect(settings.captureFps, 60);
      expect(settings.captureMaxHeight, 1440);
      expect(calls, isNotEmpty);

      await t.tap(find.byKey(const ValueKey('videoPreset:performance')));
      await t.pump();

      expect(settings.captureFps, 30);
      expect(settings.captureMaxHeight, 1080);
      expect(calls.last.captureFps, 30);
    });

    testWidgets(
        'tapping Custom only reveals Resolution/Framerate — it does not '
        'write settings or fire onChanged', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(); // Balanced: fps 60, maxHeight 1080
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      expect(find.text('Resolution'), findsNothing);
      expect(find.text('Framerate'), findsNothing);

      await t.tap(find.byKey(const ValueKey('videoPreset:custom')));
      await t.pump();

      expect(find.text('Resolution'), findsOneWidget);
      expect(find.text('Framerate'), findsOneWidget);
      expect(settings.captureFps, 60);
      expect(settings.captureMaxHeight, 1080);
      expect(calls, isEmpty);
    });

    testWidgets(
        'settings that already match no named tier reveal Custom\'s rows '
        'on their own', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureFps: 30, captureMaxHeight: 720),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(find.text('Resolution'), findsOneWidget);
      expect(find.text('Framerate'), findsOneWidget);
    });

    testWidgets(
        'editing Framerate under Custom writes settings and updates the '
        'selected card', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await t.tap(find.byKey(const ValueKey('videoPreset:custom')));
      await t.pump();
      await t.tap(find.text('30 fps'));
      await t.pump();

      expect(settings.captureFps, 30);
      expect(calls, isNotEmpty);
    });
  });

  group('Audio section', () {
    testWidgets('defaults on (AudioMode.all) and shows the "From" sub-row',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(
          t
              .widget<Switch>(
                  find.byKey(const ValueKey('recordSystemAudioSwitch')))
              .value,
          isTrue);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('All apps'), findsOneWidget);
    });

    testWidgets(
        'turning the toggle off sets AudioMode.off and hides the "From" '
        'row; turning it back on restores AudioMode.all', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await t.tap(find.byKey(const ValueKey('recordSystemAudioSwitch')));
      await t.pump();

      expect(settings.audioMode, AudioMode.off);
      expect(find.text('From'), findsNothing);
      expect(calls, isNotEmpty);

      await t.tap(find.byKey(const ValueKey('recordSystemAudioSwitch')));
      await t.pump();

      expect(settings.audioMode, AudioMode.all);
      expect(find.text('From'), findsOneWidget);
    });

    testWidgets('the "From" sub-row picks Game only (AudioMode.app)',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await t.tap(find.text('All apps'));
      await t.pumpAndSettle();
      await t.tap(find.text('Game only').last);
      await t.pumpAndSettle();

      expect(settings.audioMode, AudioMode.app);
      expect(calls, isNotEmpty);
    });

    testWidgets(
        'microphone toggle writes captureMicrophone and fires onChanged',
        (t) async {
      final calls = <AppSettings>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      expect(
          t
              .widget<Switch>(
                  find.byKey(const ValueKey('captureMicrophoneSwitch')))
              .value,
          isFalse);

      await t.tap(find.byKey(const ValueKey('captureMicrophoneSwitch')));
      await t.pump();

      expect(calls, isNotEmpty);
      expect(calls.last.captureMicrophone, isTrue);
    });

    const micInputs = [
      AudioInputInfo(
          uid: 'mic-1', name: 'Built-in Microphone', isDefault: true),
      AudioInputInfo(uid: 'mic-2', name: 'USB Microphone'),
    ];

    testWidgets(
        'no audio inputs hides the Microphone sub-row even with the mic on',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: true),
        onChanged: (_) async {},
        displays: const [],
        audioInputs: const [],
      )));

      expect(find.text('Microphone'), findsNothing);
    });

    testWidgets(
        'mic off hides the Microphone sub-row even with audio inputs listed',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: false),
        onChanged: (_) async {},
        displays: const [],
        audioInputs: micInputs,
      )));

      expect(find.text('Microphone'), findsNothing);
    });

    testWidgets(
        'mic on with audio inputs shows the Microphone sub-row, '
        'defaulting to "System default"', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: true),
        onChanged: (_) async {},
        displays: const [],
        audioInputs: micInputs,
      )));

      expect(find.text('Microphone'), findsOneWidget);
      // The default entry NAMES what "System default" resolves to right now
      // (the input flagged isDefault) — a bare "System default" made the
      // maintainer ask what it meant.
      expect(find.text('System default (Built-in Microphone)'), findsOneWidget);
    });

    testWidgets('picking a device writes micDeviceUid and fires onChanged',
        (t) async {
      final calls = <AppSettings>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: true),
        onChanged: (s) async => calls.add(s),
        displays: const [],
        audioInputs: micInputs,
      )));

      await t.tap(find.byKey(const ValueKey('micDeviceDropdown')));
      await t.pumpAndSettle();
      await t.tap(find.text('USB Microphone').last);
      await t.pumpAndSettle();

      expect(calls, isNotEmpty);
      expect(calls.last.micDeviceUid, 'mic-2');
    });

    testWidgets('picking "System default" reverts micDeviceUid to null',
        (t) async {
      final calls = <AppSettings>[];
      final settings =
          AppSettings(captureMicrophone: true, micDeviceUid: 'mic-1');
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
        audioInputs: micInputs,
      )));

      expect(find.text('Built-in Microphone'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('micDeviceDropdown')));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('System default').last);
      await t.pumpAndSettle();

      expect(calls, isNotEmpty);
      expect(calls.last.micDeviceUid, isNull);
    });

    testWidgets(
        'a saved uid not in audioInputs shows as "System default" without '
        'touching the persisted setting', (t) async {
      final settings =
          AppSettings(captureMicrophone: true, micDeviceUid: 'mic-unplugged');
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (_) async {},
        displays: const [],
        audioInputs: micInputs,
      )));

      expect(find.textContaining('System default'), findsOneWidget);
      expect(settings.micDeviceUid, 'mic-unplugged');
    });

    testWidgets('mic volume slider hidden when the mic is off', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: false),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(find.byKey(const ValueKey('micVolumeSlider')), findsNothing);
      expect(find.byKey(const ValueKey('micListenButton')), findsNothing);
    });

    testWidgets(
        'mic volume slider shows even with no audio inputs listed (only '
        'gated on the mic being on, unlike the device dropdown)', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: true),
        onChanged: (_) async {},
        displays: const [],
        audioInputs: const [],
      )));

      expect(find.byKey(const ValueKey('micVolumeSlider')), findsOneWidget);
      expect(find.byKey(const ValueKey('micListenButton')), findsOneWidget);
    });

    testWidgets('mic volume slider shows the current percent label', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: true, micVolume: 1.0),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets(
        'dragging the mic volume slider writes micVolume on '
        'drag end, not per pixel', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(captureMicrophone: true);
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      final slider = find.byKey(const ValueKey('micVolumeSlider'));
      expect(slider, findsOneWidget);

      // WidgetTester.drag performs one down->move->up gesture, so this
      // exercises Slider's onChangeEnd (fired once on release), not the
      // per-pixel onChanged stream.
      await t.drag(slider, const Offset(60, 0));
      await t.pump();

      expect(calls, isNotEmpty);
      expect(settings.micVolume, isNot(1.0));
      expect(calls.last.micVolume, settings.micVolume);
    });

    testWidgets(
        'the listen button calls onSetMicMonitoring(true) then (false) on '
        'toggle off, and shows an active state while on', (t) async {
      final monitoringCalls = <bool>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: true),
        onChanged: (_) async {},
        displays: const [],
        onSetMicMonitoring: (enabled) => monitoringCalls.add(enabled),
      )));

      await t.tap(find.byKey(const ValueKey('micListenButton')));
      await t.pump();
      expect(monitoringCalls, [true]);

      await t.tap(find.byKey(const ValueKey('micListenButton')));
      await t.pump();
      expect(monitoringCalls, [true, false]);
    });

    testWidgets(
        'turning "Record my microphone" off while listening turns '
        'listening off too', (t) async {
      final monitoringCalls = <bool>[];
      final settings = AppSettings(captureMicrophone: true);
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (_) async {},
        displays: const [],
        onSetMicMonitoring: (enabled) => monitoringCalls.add(enabled),
      )));

      await t.tap(find.byKey(const ValueKey('micListenButton')));
      await t.pump();
      expect(monitoringCalls, [true]);

      await t.tap(find.byKey(const ValueKey('captureMicrophoneSwitch')));
      await t.pump();

      expect(settings.captureMicrophone, isFalse);
      expect(monitoringCalls, [true, false]);
    });

    testWidgets(
        'disposing the settings screen while listening calls '
        'onSetMicMonitoring(false)', (t) async {
      final monitoringCalls = <bool>[];
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(captureMicrophone: true),
        onChanged: (_) async {},
        displays: const [],
        onSetMicMonitoring: (enabled) => monitoringCalls.add(enabled),
      )));

      await t.tap(find.byKey(const ValueKey('micListenButton')));
      await t.pump();
      expect(monitoringCalls, [true]);

      // Replace the whole tree so SettingsScreen's State disposes.
      await t.pumpWidget(_app(const SizedBox()));

      expect(monitoringCalls, [true, false]);
    });
  });

  group('Storage section', () {
    /// Blur the focused field — limits commit on LEAVING the field, never
    /// per keystroke (see _commitLimit's doc: typing "15" passes through
    /// "1", and a per-keystroke commit ran a retention sweep on the
    /// transient value and deleted real clips).
    Future<void> blur(WidgetTester t) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
    }

    testWidgets('max storage commits on blur; blank commits null (unlimited)',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await openPage(t, 'Storage');
      final field = find.byKey(const ValueKey('maxStorageField'));
      await t.enterText(field, '50');
      await blur(t);
      expect(settings.maxStorageGb, 50);

      await t.enterText(field, '');
      await blur(t);
      expect(settings.maxStorageGb, isNull);

      // Garbage neither commits nor clears the previous value, and the
      // field snaps back to what's actually committed.
      await t.enterText(field, '5');
      await blur(t);
      await t.enterText(field, 'abc');
      await blur(t);
      expect(settings.maxStorageGb, 5);
      expect(t.widget<TextField>(field).controller!.text, '5');
      expect(calls, isNotEmpty);
    });

    testWidgets(
        'REGRESSION: typing "1" en route to "15" neither commits nor fires '
        'onChanged until the field is left — a transient keystroke must '
        'never trigger a retention sweep', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(maxStorageGb: 20);
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await openPage(t, 'Storage');
      final field = find.byKey(const ValueKey('maxStorageField'));

      // Mid-typing: the transient "1" exists only in the text field.
      await t.enterText(field, '1');
      await t.pump();
      expect(settings.maxStorageGb, 20);
      expect(calls, isEmpty);

      await t.enterText(field, '15');
      await t.pump();
      expect(settings.maxStorageGb, 20);
      expect(calls, isEmpty);

      // Leaving the field commits the FINAL value, exactly once.
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(settings.maxStorageGb, 15);
      expect(calls, hasLength(1));
    });

    testWidgets(
        'Clean up now runs the wired cleanup once and reports removed '
        'clips + freed space', (t) async {
      var runs = 0;
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(maxStorageGb: 20),
        onChanged: (_) async {},
        displays: const [],
        onCleanUpStorage: () async {
          runs++;
          return [
            Clip(
              path: '/tmp/a.mp4',
              gameId: 'g',
              event: GameEventKind.manual,
              createdAt: DateTime(2026),
              sizeBytes: 3 * 1024 * 1024,
            ),
            Clip(
              path: '/tmp/b.mp4',
              gameId: 'g',
              event: GameEventKind.manual,
              createdAt: DateTime(2026),
              sizeBytes: 1024 * 1024,
            ),
          ];
        },
      )));

      await openPage(t, 'Storage');
      await t.tap(find.byKey(const ValueKey('cleanUpStorageButton')));
      await t.pump();
      await t.pump();

      expect(runs, 1);
      expect(find.textContaining('Removed 2 clips'), findsOneWidget);
      expect(find.textContaining('4.0 MB'), findsOneWidget);
    });

    testWidgets('Clean up now with nothing over limit says so', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        onCleanUpStorage: () async => const [],
      )));

      await openPage(t, 'Storage');
      await t.tap(find.byKey(const ValueKey('cleanUpStorageButton')));
      await t.pump();
      await t.pump();

      expect(find.textContaining('Nothing to remove'), findsOneWidget);
    });

    testWidgets('Clean up row is absent when no cleanup is wired', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Storage');
      expect(find.byKey(const ValueKey('cleanUpStorageButton')), findsNothing);
    });

    testWidgets('max age (days) commits on blur; blank commits null (never)',
        (t) async {
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Storage');
      final field = find.byKey(const ValueKey('maxAgeField'));
      await t.enterText(field, '14');
      await blur(t);
      expect(settings.maxClipAgeDays, 14);

      await t.enterText(field, '');
      await blur(t);
      expect(settings.maxClipAgeDays, isNull);
    });

    testWidgets(
        'recordings folder shows the override and Reset clears it back to '
        'the default', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(clipsDirPath: '/Volumes/gaming/Clips');
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await openPage(t, 'Storage');
      expect(find.text('/Volumes/gaming/Clips'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('resetClipsDirButton')));
      await t.pump();

      expect(settings.clipsDirPath, isNull);
      expect(calls, isNotEmpty);
      // Back on the default: the Reset button disappears.
      expect(find.byKey(const ValueKey('resetClipsDirButton')), findsNothing);
    });
  });

  group('Steam section', () {
    Future<void> blur(WidgetTester t) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
    }

    testWidgets('fields render the current settings values', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(
          steamId64: '76561197960287930',
          steamWebApiKey: 'ABCDEF0123456789',
        ),
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Steam');
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('steamIdField')))
            .controller!
            .text,
        '76561197960287930',
      );
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('steamApiKeyField')))
            .controller!
            .text,
        'ABCDEF0123456789',
      );
    });

    testWidgets('the API key field is obscured', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));
      await openPage(t, 'Steam');
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('steamApiKeyField')))
            .obscureText,
        isTrue,
      );
    });

    testWidgets('the SteamID field commits on blur and fires onChanged',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await openPage(t, 'Steam');
      await t.enterText(
          find.byKey(const ValueKey('steamIdField')), '76561197960287930');
      await blur(t);

      expect(settings.steamId64, '76561197960287930');
      expect(calls, isNotEmpty);
    });

    testWidgets(
        'a pasted profile URL is normalized down to its trailing segment '
        'at commit', (t) async {
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Steam');
      await t.enterText(
        find.byKey(const ValueKey('steamIdField')),
        'https://steamcommunity.com/id/someVanityName',
      );
      await blur(t);

      expect(settings.steamId64, 'someVanityName');
    });

    testWidgets('a profiles/<id64> URL normalizes to the bare id64', (t) async {
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Steam');
      await t.enterText(
        find.byKey(const ValueKey('steamIdField')),
        'https://steamcommunity.com/profiles/76561197960287930',
      );
      await blur(t);

      expect(settings.steamId64, '76561197960287930');
    });

    testWidgets('the API key field commits on blur and fires onChanged',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (s) async => calls.add(s),
        displays: const [],
      )));

      await openPage(t, 'Steam');
      await t.enterText(
          find.byKey(const ValueKey('steamApiKeyField')), 'MYKEY123');
      await blur(t);

      expect(settings.steamWebApiKey, 'MYKEY123');
      expect(calls, isNotEmpty);
    });

    testWidgets(
        'the auto-clip toggle defaults on and writes '
        'clipSteamAchievements', (t) async {
      final settings = AppSettings();
      await t.pumpWidget(_app(SettingsScreen(
        settings: settings,
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Steam');
      final toggle = find.byKey(const ValueKey('steamClipToggle'));
      expect(t.widget<Switch>(toggle).value, isTrue);

      await t.tap(toggle);
      await t.pump();
      expect(settings.clipSteamAchievements, isFalse);
    });

    testWidgets(
        'with no watcher wired (steamStatus null), the status line shows a '
        'static "not configured" message', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Steam');
      expect(find.byKey(const ValueKey('steamStatusLine')), findsOneWidget);
      expect(find.textContaining('Add your Steam ID'), findsOneWidget);
    });

    testWidgets(
        'with a watcher wired, the status line reflects its live status '
        'notifier', (t) async {
      final status = ValueNotifier<String?>('Waiting for a Steam game');
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        steamStatus: status,
      )));

      await openPage(t, 'Steam');
      expect(find.text('Waiting for a Steam game'), findsOneWidget);

      status.value = 'Watching (in Counter-Strike 2)';
      await t.pump();
      expect(find.text('Watching (in Counter-Strike 2)'), findsOneWidget);
    });

    testWidgets('a null status value falls back to an idle message', (t) async {
      final status = ValueNotifier<String?>(null);
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
        steamStatus: status,
      )));

      await openPage(t, 'Steam');
      expect(find.byKey(const ValueKey('steamStatusLine')), findsOneWidget);
      expect(find.textContaining('Idle'), findsOneWidget);
    });

    testWidgets('the privacy hint mentions Game details must be Public',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      await openPage(t, 'Steam');
      expect(find.textContaining('Game details'), findsWidgets);
    });
  });

  testWidgets('the default buffer offers 15 s, same as a per-game override',
      (t) async {
    // The global default offered only 30/60/Custom while a game hub's
    // override offered 15/30/60/Custom — so the shortest buffer the app
    // advertises ("the last 15-60 s") couldn't be set as the default.
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    expect(find.text('15 s'), findsOneWidget);
    await t.tap(find.text('15 s'));
    await t.pump();

    expect(calls.last.defaultBufferSeconds, 15);
  });

  testWidgets('a saved 15 s selects its segment instead of falling to Custom',
      (t) async {
    // The custom-detection didn't list 15, so a stored 15 was treated as a
    // custom value and no segment highlighted.
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings()..defaultBufferSeconds = 15,
      onChanged: (_) async {},
      displays: const [],
    )));

    final seg = t.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>).first);
    expect(seg.selected, {'15'});
  });

  testWidgets('About shows Riot\'s required legal boilerplate verbatim',
      (t) async {
    // Riot's Developer API Policy REQUIRES this text, unmodified, "in a
    // location that is readily visible to players" for any product using
    // their APIs or game-specific static data — Rewind does both (Live
    // Client Data API + Data Dragon art). This test exists so it can't be
    // reworded or dropped by accident. See docs/COMPLIANCE.md.
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
    )));

    await openPage(t, 'About');
    final text =
        t.widget<Text>(find.byKey(const ValueKey('riotDisclaimer'))).data!;
    expect(text, kRiotDisclaimer);
    expect(
        text,
        'Rewind is not endorsed by Riot Games and does not reflect the views '
        'or opinions of Riot Games or anyone officially involved in producing '
        'or managing Riot Games properties. Riot Games and all associated '
        'properties are trademarks or registered trademarks of Riot Games, '
        'Inc.');
  });

  group('Sidebar', () {
    testWidgets('the default page is Capture', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(find.text('Instant replay'), findsOneWidget);
      expect(find.text('Save clip'), findsNothing);
    });

    testWidgets('switching pages shows that page and hides the previous one',
        (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      expect(find.text('Instant replay'), findsOneWidget);
      expect(find.text('Save clip'), findsNothing);

      await openPage(t, 'Hotkey');
      expect(find.text('Save clip'), findsOneWidget);
      expect(find.text('Instant replay'), findsNothing);

      await openPage(t, 'Storage');
      expect(find.text('Max storage (GB)'), findsOneWidget);
      expect(find.text('Save clip'), findsNothing);

      await openPage(t, 'About');
      expect(find.byKey(const ValueKey('riotDisclaimer')), findsOneWidget);
      expect(find.text('Max storage (GB)'), findsNothing);

      await openPage(t, 'Capture');
      expect(find.text('Instant replay'), findsOneWidget);
      expect(find.byKey(const ValueKey('riotDisclaimer')), findsNothing);
    });

    testWidgets(
        'the selected page carries a non-colour indicator, not just accent '
        'text', (t) async {
      await t.pumpWidget(_app(SettingsScreen(
        settings: AppSettings(),
        onChanged: (_) async {},
        displays: const [],
      )));

      BorderSide leftBorderOf(String id) {
        final container = t.widget<Container>(find.descendant(
          of: find.byKey(ValueKey('settingsTab:$id')),
          matching: find.byType(Container),
        ));
        final decoration = container.decoration! as BoxDecoration;
        return (decoration.border! as Border).left;
      }

      // Capture is the default page: its indicator is drawn, Hotkey's isn't.
      expect(leftBorderOf('Capture').width, greaterThan(0));
      expect(leftBorderOf('Capture').color, isNot(Colors.transparent));
      expect(leftBorderOf('Hotkey').color, Colors.transparent);

      await openPage(t, 'Hotkey');
      expect(leftBorderOf('Hotkey').color, isNot(Colors.transparent));
      expect(leftBorderOf('Capture').color, Colors.transparent);
    });
  });

  testWidgets('the close button fires onClose', (t) async {
    var closed = false;
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      onClose: () => closed = true,
    )));

    await t.tap(find.byKey(const ValueKey('settingsCloseButton')));
    await t.pump();

    expect(closed, isTrue);
  });

  testWidgets('the close button is present and inert without onClose wired',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
    )));

    expect(find.byKey(const ValueKey('settingsCloseButton')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('settingsCloseButton')));
    await t.pump(); // does not throw
  });
}
