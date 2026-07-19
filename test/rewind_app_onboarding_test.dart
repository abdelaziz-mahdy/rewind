import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/main.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/theme.dart';

/// Covers Task 18's onboarding/buffer-policy override: `RewindApp` mirrors
/// whether onboarding is on screen into the `onboardingActive` notifier
/// `main()`'s `applyBufferPolicy` consults (so "Try it now" can save a clip
/// at the desktop even though `captureOnlyInGame` now defaults to true), and
/// clears it the moment onboarding finishes or is skipped — see
/// `RewindApp.onboardingActive`'s doc.
void main() {
  late Directory tmp;
  late ClipLibrary library;
  late ClipCoordinator coordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_app_onboarding');
    library = ClipLibrary(clipsDir: tmp);
    coordinator = ClipCoordinator(
      registry: GameRegistry(sources: []),
      library: library,
      storage: StorageManager(library),
      settings: AppSettings(),
      outDir: tmp.path,
      engine: null,
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Widget app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

  RewindApp rewindApp({
    required AppSettings settings,
    required ValueNotifier<bool> onboardingActive,
  }) =>
      RewindApp(
        coordinator: coordinator,
        library: library,
        settings: settings,
        captureError: null,
        bufferActive: ValueNotifier<bool>(false),
        displays: const [],
        capturableApps: const [],
        onSettingsChanged: (_) async {},
        onHotkeyRecording: (_) async {},
        onOpenClipsFolder: () {},
        onboardingActive: onboardingActive,
      );

  testWidgets(
      'onboarding visible on a fresh install keeps onboardingActive true',
      (t) async {
    final settings = AppSettings(); // onboardingComplete: false
    final onboardingActive = ValueNotifier<bool>(!settings.onboardingComplete);
    expect(onboardingActive.value, isTrue);

    await t.pumpWidget(app(rewindApp(
      settings: settings,
      onboardingActive: onboardingActive,
    )));

    expect(find.text('Never miss a play'), findsOneWidget); // onboarding
    expect(onboardingActive.value, isTrue);
  });

  testWidgets('Skip clears onboardingActive so the policy can re-apply',
      (t) async {
    final settings = AppSettings();
    final onboardingActive = ValueNotifier<bool>(!settings.onboardingComplete);
    var reapplied = 0;
    onboardingActive.addListener(() {
      if (!onboardingActive.value) reapplied++;
    });

    await t.pumpWidget(app(rewindApp(
      settings: settings,
      onboardingActive: onboardingActive,
    )));

    await t.tap(find.byKey(const ValueKey('onboardingSkip')));
    await t.pump();

    expect(onboardingActive.value, isFalse);
    expect(reapplied, 1);
    expect(settings.onboardingComplete, isTrue);
  });

  testWidgets(
      'finishing onboarding via Get started clears onboardingActive and '
      'shows the Shell', (t) async {
    final settings = AppSettings();
    final onboardingActive = ValueNotifier<bool>(!settings.onboardingComplete);

    await t.pumpWidget(app(rewindApp(
      settings: settings,
      onboardingActive: onboardingActive,
    )));

    // Page through every onboarding step with pumpAndSettle — safe while
    // still on onboarding (no infinite animation there). The LAST tap
    // (welcome/permission/buffer/preferences/controls/try-it = 6 pages, 5
    // page transitions) fires onDone instead of animating a page, and lands
    // on the Shell, whose recorder deck's dot animates forever — bounded
    // pumps only from there (see CLAUDE.md's testing gotchas).
    for (var i = 0; i < 5; i++) {
      await t.tap(find.byKey(const ValueKey('onboardingNext')));
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const ValueKey('onboardingNext')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(onboardingActive.value, isFalse);
    expect(find.text('Never miss a play'), findsNothing);
  });

  testWidgets('an already-onboarded install never flips onboardingActive true',
      (t) async {
    final settings = AppSettings()..onboardingComplete = true;
    final onboardingActive = ValueNotifier<bool>(!settings.onboardingComplete);
    expect(onboardingActive.value, isFalse);

    await t.pumpWidget(app(rewindApp(
      settings: settings,
      onboardingActive: onboardingActive,
    )));
    await t.pump(const Duration(milliseconds: 100));

    expect(find.text('Never miss a play'), findsNothing);
    expect(onboardingActive.value, isFalse);
  });
}
