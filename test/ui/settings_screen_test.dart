import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/obs/app_info.dart';
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

void main() {
  testWidgets('recording Alt+F10 updates settings and fires onChanged',
      (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

    await _startRecording(t);
    expect(find.text('Press keys…'), findsOneWidget);

    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.f10);
    await t.pump();

    expect(calls, isNotEmpty);
    expect(calls.last.hotkey, 'Alt+F10');
    expect(find.text('Alt+F10'), findsOneWidget);

    await t.sendKeyUpEvent(LogicalKeyboardKey.f10);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
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

    expect(find.text('Alt+F10'), findsOneWidget); // save hotkey
    expect(find.text('Alt+F9'), findsOneWidget); // record hotkey
  });

  testWidgets(
      'recording a combo in the record hotkey field updates '
      'settings.recordHotkey without touching settings.hotkey', (t) async {
    // The record field sits below the (mic-toggle-taller) Capture section —
    // off the default viewport's ListView build extent.
    t.view.physicalSize = const Size(1200, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
      displays: const [],
    )));

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
    t.view.physicalSize = const Size(1200, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final recording = <bool>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      onHotkeyRecording: (r) async => recording.add(r),
    )));

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

    await t.tap(find.text('Custom'));
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

  testWidgets('no displays hides the Capture display section', (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
    )));

    expect(find.textContaining('Capture display'), findsNothing);
  });

  const displays = [
    DisplayInfo(uuid: 'uuid-1', width: 1920, height: 1080, isMain: true),
    DisplayInfo(uuid: 'uuid-2', width: 2560, height: 1440, isMain: false),
  ];

  testWidgets('capture display section lists displays, main pre-selected',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: displays,
    )));

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

  testWidgets('no capturable apps hides the Capture application section',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      capturableApps: const [],
    )));

    expect(find.textContaining('Capture application'), findsNothing);
  });

  testWidgets(
      'capture application section lists apps plus "Entire display", '
      'defaulting to "Entire display"', (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
      capturableApps: apps,
    )));

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

    expect(find.text('Entire display'), findsOneWidget);
    expect(settings.captureAppBundleId, 'com.example.stale');
  });

  testWidgets(
      'the Per-game section is gone — per-game settings live in '
      'each game\'s hub now', (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      displays: const [],
    )));

    expect(find.textContaining('Per-game'), findsNothing);
  });

  testWidgets('the follow-the-game switch defaults on and reflects settings',
      (t) async {
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(autoSwitchCapture: false),
      onChanged: (_) async {},
      displays: const [],
    )));

    expect(find.text('Follow the game'), findsOneWidget);
    final sw =
        t.widget<Switch>(find.byKey(const ValueKey('autoSwitchCaptureSwitch')));
    expect(sw.value, isFalse);
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

  Future<void> pumpTall(WidgetTester t, Widget child) async {
    // The settings ListView is long; without a tall viewport lower sections
    // never build (see CLAUDE.md's testing gotchas).
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(child);
  }

  group('Recording quality section', () {
    testWidgets('framerate, resolution, and system audio commit + persist',
        (t) async {
      final settings = AppSettings();
      final calls = <AppSettings>[];
      await pumpTall(
          t,
          _app(SettingsScreen(
            settings: settings,
            onChanged: (s) async => calls.add(s),
            displays: const [],
          )));

      await t.tap(find.text('30 fps'));
      await t.pump();
      expect(settings.captureFps, 30);

      await t.tap(find.text('1080p'));
      await t.pump();
      expect(settings.captureMaxHeight, 1080);

      await t.tap(find.text('Source'));
      await t.pump();
      expect(settings.captureMaxHeight, isNull);

      await t.tap(find.text('Game only'));
      await t.pump();
      expect(settings.audioMode, AudioMode.app);

      await t.tap(find.text('None'));
      await t.pump();
      expect(settings.audioMode, AudioMode.off);
      expect(calls, isNotEmpty);
    });
  });

  group('Storage section', () {
    testWidgets('max storage commits ints; blank commits null (unlimited)',
        (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings();
      await pumpTall(
          t,
          _app(SettingsScreen(
            settings: settings,
            onChanged: (s) async => calls.add(s),
            displays: const [],
          )));

      final field = find.byKey(const ValueKey('maxStorageField'));
      await t.enterText(field, '50');
      await t.pump();
      expect(settings.maxStorageGb, 50);

      await t.enterText(field, '');
      await t.pump();
      expect(settings.maxStorageGb, isNull);

      // Garbage neither commits nor resets the previous value.
      await t.enterText(field, '5');
      await t.pump();
      await t.enterText(field, 'abc');
      await t.pump();
      expect(settings.maxStorageGb, 5);
      expect(calls, isNotEmpty);
    });

    testWidgets('max age (days) commits ints; blank commits null (never)',
        (t) async {
      final settings = AppSettings();
      await pumpTall(
          t,
          _app(SettingsScreen(
            settings: settings,
            onChanged: (_) async {},
            displays: const [],
          )));

      final field = find.byKey(const ValueKey('maxAgeField'));
      await t.enterText(field, '14');
      await t.pump();
      expect(settings.maxClipAgeDays, 14);

      await t.enterText(field, '');
      await t.pump();
      expect(settings.maxClipAgeDays, isNull);
    });

    testWidgets(
        'recordings folder shows the override and Reset clears it back to '
        'the default', (t) async {
      final calls = <AppSettings>[];
      final settings = AppSettings(clipsDirPath: '/Volumes/gaming/Clips');
      await pumpTall(
          t,
          _app(SettingsScreen(
            settings: settings,
            onChanged: (s) async => calls.add(s),
            displays: const [],
          )));

      expect(find.text('/Volumes/gaming/Clips'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('resetClipsDirButton')));
      await t.pump();

      expect(settings.clipsDirPath, isNull);
      expect(calls, isNotEmpty);
      // Back on the default: the Reset button disappears.
      expect(find.byKey(const ValueKey('resetClipsDirButton')), findsNothing);
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
}
