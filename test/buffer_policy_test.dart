import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/coordinator/buffer_policy.dart';

void main() {
  group('desiredBufferActive', () {
    test('captureOnlyInGame OFF: always on, game or no game, no override', () {
      expect(
          desiredBufferActive(
              captureOnlyInGame: false,
              anyGameActive: false,
              manualOverride: null),
          isTrue);
      expect(
          desiredBufferActive(
              captureOnlyInGame: false,
              anyGameActive: true,
              manualOverride: null),
          isTrue);
    });

    test('captureOnlyInGame ON, no override: active game resumes the buffer',
        () {
      expect(
          desiredBufferActive(
              captureOnlyInGame: true,
              anyGameActive: true,
              manualOverride: null),
          isTrue);
    });

    test(
        'captureOnlyInGame ON, no override: no active game pauses the '
        'buffer', () {
      expect(
          desiredBufferActive(
              captureOnlyInGame: true,
              anyGameActive: false,
              manualOverride: null),
          isFalse);
    });

    test(
        'a manual tray Pause wins even with a game active and the setting '
        'OFF', () {
      expect(
          desiredBufferActive(
              captureOnlyInGame: false,
              anyGameActive: true,
              manualOverride: false),
          isFalse);
    });

    test(
        'a manual tray Resume forces the buffer on with no game active and '
        'the setting ON', () {
      expect(
          desiredBufferActive(
              captureOnlyInGame: true,
              anyGameActive: false,
              manualOverride: true),
          isTrue);
    });
  });

  group('isAutoPaused', () {
    test('true only when captureOnlyInGame paused it with no override', () {
      expect(
          isAutoPaused(
              captureOnlyInGame: true,
              anyGameActive: false,
              manualOverride: null),
          isTrue);
    });

    test('false while the buffer is running', () {
      expect(
          isAutoPaused(
              captureOnlyInGame: true,
              anyGameActive: true,
              manualOverride: null),
          isFalse);
      expect(
          isAutoPaused(
              captureOnlyInGame: false,
              anyGameActive: false,
              manualOverride: null),
          isFalse);
    });

    test(
        'false for a manual pause — that reads "Paused", not "Waiting for '
        'a game"', () {
      expect(
          isAutoPaused(
              captureOnlyInGame: true,
              anyGameActive: false,
              manualOverride: false),
          isFalse);
    });

    test('false while a manual Resume override forces the buffer on', () {
      expect(
          isAutoPaused(
              captureOnlyInGame: true,
              anyGameActive: false,
              manualOverride: true),
          isFalse);
    });
  });

  // main.dart's applyBufferPolicy never passes `settings.captureOnlyInGame`
  // straight through — it composes `settings.captureOnlyInGame &&
  // !onboardingActive.value` first (see that file's `onboardingActive` doc)
  // so onboarding's "Try it now" step still saves a clip at the desktop
  // under the new default-ON setting. buffer_policy.dart's pure functions
  // stay setting-only; this group exercises them with that exact
  // composition to cover the override end to end.
  group('main.dart\'s onboardingActive override composition', () {
    test(
        'onboarding visible: buffer stays on with captureOnlyInGame ON and '
        'no game active', () {
      const captureOnlyInGame = true;
      const onboardingActive = true;
      const effective = captureOnlyInGame && !onboardingActive;
      expect(
          desiredBufferActive(
              captureOnlyInGame: effective,
              anyGameActive: false,
              manualOverride: null),
          isTrue);
      expect(
          isAutoPaused(
              captureOnlyInGame: effective,
              anyGameActive: false,
              manualOverride: null),
          isFalse);
    });

    test(
        'onboarding dismissed: the policy reclaims control and pauses with '
        'no game active', () {
      const captureOnlyInGame = true;
      const onboardingActive = false;
      const effective = captureOnlyInGame && !onboardingActive;
      expect(
          desiredBufferActive(
              captureOnlyInGame: effective,
              anyGameActive: false,
              manualOverride: null),
          isFalse);
      expect(
          isAutoPaused(
              captureOnlyInGame: effective,
              anyGameActive: false,
              manualOverride: null),
          isTrue); // "Waiting for a game", not "Paused"
    });
  });

  group('clearedOverrideAfterTransition', () {
    test('a temporary Resume override (true) is cleared on transition', () {
      expect(clearedOverrideAfterTransition(true), isNull);
    });

    test('a sticky manual Pause (false) survives a transition', () {
      expect(clearedOverrideAfterTransition(false), isFalse);
    });

    test('no override (null) stays null', () {
      expect(clearedOverrideAfterTransition(null), isNull);
    });
  });
}
