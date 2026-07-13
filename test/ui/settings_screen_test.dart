import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/obs/display_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/settings_screen.dart';
import 'package:rewind/src/ui/theme.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

/// Taps the hotkey recorder field, putting it into "Press keys…" state.
Future<void> _startRecording(WidgetTester t) async {
  await t.tap(find.textContaining(RegExp(r'Click to set a hotkey|^Alt\+')));
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
}
