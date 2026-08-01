import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/coordinator/buffer_policy.dart';
import 'package:rewind/src/obs/buffer_transition.dart';
import 'fakes/fake_capture_engine.dart';

void main() {
  group('applyBufferTransition', () {
    test('turning ON resumes capture BEFORE starting the buffer', () {
      final engine = FakeCaptureEngine();
      final result = applyBufferTransition(engine, desired: true);

      expect(engine.calls, ['resumeCapture', 'start']);
      expect(result.active, isTrue);
      expect(engine.captureSuspended, isFalse);
    });

    test('turning OFF stops the buffer BEFORE suspending capture', () {
      final engine = FakeCaptureEngine();
      final result = applyBufferTransition(engine, desired: false);

      expect(engine.calls, ['stop', 'suspendCapture']);
      expect(result.active, isFalse);
      expect(engine.captureSuspended, isTrue);
    });

    test(
        'a manual tray pause (desiredBufferActive resolves to false via a '
        'manualOverride) also suspends capture, same as an auto-pause', () {
      final engine = FakeCaptureEngine();
      final desired = desiredBufferActive(
        captureOnlyInGame: false, // setting OFF — would otherwise stay on
        anyGameActive: true,
        manualOverride: false, // the tray's manual Pause
      );
      expect(desired, isFalse);

      applyBufferTransition(engine, desired: desired);

      expect(engine.calls, ['stop', 'suspendCapture']);
      expect(engine.captureSuspended, isTrue);
    });

    test('idempotent: repeated OFF transitions keep re-suspending safely', () {
      final engine = FakeCaptureEngine();
      applyBufferTransition(engine, desired: false);
      applyBufferTransition(engine, desired: false);

      expect(
          engine.calls, ['stop', 'suspendCapture', 'stop', 'suspendCapture']);
      expect(engine.captureSuspended, isTrue);
    });

    test('idempotent: repeated ON transitions keep re-resuming safely', () {
      final engine = FakeCaptureEngine();
      applyBufferTransition(engine, desired: true);
      applyBufferTransition(engine, desired: true);

      expect(
          engine.calls, ['resumeCapture', 'start', 'resumeCapture', 'start']);
      expect(engine.captureSuspended, isFalse);
    });

    // The step results exist so main.dart can LOG a failure instead of
    // silently carrying on. A suspend that doesn't take is the worst case:
    // macOS keeps its screen-recording indicator up and the idle CPU/GPU
    // cost the pause was meant to save is still being paid, with nothing
    // anywhere saying so.
    test('reports which step failed', () {
      final engine = FakeCaptureEngine()..suspendCaptureFails = true;
      final off = applyBufferTransition(engine, desired: false);
      expect(off.sourceOk, isFalse);
      expect(off.bufferOk, isTrue);

      final engine2 = FakeCaptureEngine()..startBufferFails = true;
      final on = applyBufferTransition(engine2, desired: true);
      expect(on.bufferOk, isFalse);
      expect(on.active, isFalse);
    });

    test('a null engine (dev mode, no capture backend) no-ops both ways', () {
      expect(applyBufferTransition(null, desired: true).active, isFalse);
      expect(applyBufferTransition(null, desired: false).active, isFalse);
    });
  });
}
