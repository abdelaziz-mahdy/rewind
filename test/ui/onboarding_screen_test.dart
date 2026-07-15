import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/onboarding_screen.dart';
import 'package:rewind/src/ui/theme.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

void main() {
  OnboardingScreen screen({
    AppSettings? settings,
    Future<void> Function(AppSettings)? onChanged,
    VoidCallback? onDone,
    Future<void> Function()? onOpenScreenRecording,
  }) =>
      OnboardingScreen(
        settings: settings ?? AppSettings(),
        onChanged: onChanged ?? (_) async {},
        onDone: onDone ?? () {},
        onOpenScreenRecording: onOpenScreenRecording,
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

  testWidgets('the permission step opens Screen Recording settings', (t) async {
    var opened = 0;
    await t
        .pumpWidget(_app(screen(onOpenScreenRecording: () async => opened++)));
    await nextTo(t, 1);
    await t.tap(find.byKey(const ValueKey('onboardingStepAction')));
    await t.pump();
    expect(opened, 1);
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

  testWidgets('the last step finishes via Get started', (t) async {
    var done = 0;
    await t.pumpWidget(_app(screen(onDone: () => done++)));
    await nextTo(t, 4); // to the final step
    expect(find.widgetWithText(FilledButton, 'Get started'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    expect(done, 1);
  });

  testWidgets('Skip invokes onDone immediately', (t) async {
    var done = 0;
    await t.pumpWidget(_app(screen(onDone: () => done++)));
    await t.tap(find.byKey(const ValueKey('onboardingSkip')));
    expect(done, 1);
  });
}
