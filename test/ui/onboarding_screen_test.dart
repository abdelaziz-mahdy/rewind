import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/onboarding_screen.dart';
import 'package:rewind/src/ui/theme.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

void main() {
  OnboardingScreen screen({
    VoidCallback? onDone,
    Future<void> Function()? onOpenScreenRecording,
  }) =>
      OnboardingScreen(
        hotkey: 'Alt+F10',
        recordHotkey: 'Alt+F9',
        onDone: onDone ?? () {},
        onOpenScreenRecording: onOpenScreenRecording,
      );

  testWidgets('opens on the welcome step and shows the hotkeys later',
      (t) async {
    await t.pumpWidget(_app(screen()));
    expect(find.text('Never miss a play'), findsOneWidget);

    // Page to the controls step; it names the actual hotkeys.
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    await t.pumpAndSettle();
    expect(find.textContaining('Alt+F10'), findsOneWidget);
    expect(find.textContaining('Alt+F9'), findsOneWidget);
  });

  testWidgets('the permission step opens Screen Recording settings', (t) async {
    var opened = 0;
    await t
        .pumpWidget(_app(screen(onOpenScreenRecording: () async => opened++)));
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('onboardingStepAction')));
    await t.pump();
    expect(opened, 1);
  });

  testWidgets('Skip invokes onDone immediately', (t) async {
    var done = 0;
    await t.pumpWidget(_app(screen(onDone: () => done++)));
    await t.tap(find.byKey(const ValueKey('onboardingSkip')));
    expect(done, 1);
  });

  testWidgets('the last step\'s button says Get started and finishes',
      (t) async {
    var done = 0;
    await t.pumpWidget(_app(screen(onDone: () => done++)));
    // Advance through all steps.
    for (var i = 0; i < 3; i++) {
      await t.tap(find.byKey(const ValueKey('onboardingNext')));
      await t.pumpAndSettle();
    }
    expect(find.widgetWithText(FilledButton, 'Get started'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    expect(done, 1);
  });

  testWidgets('Back returns to the previous step', (t) async {
    await t.pumpWidget(_app(screen()));
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    await t.pumpAndSettle();
    expect(find.text('Grant Screen Recording'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('onboardingBack')));
    await t.pumpAndSettle();
    expect(find.text('Never miss a play'), findsOneWidget);
  });
}
