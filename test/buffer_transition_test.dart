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
      expect(result, isTrue);
      expect(engine.captureSuspended, isFalse);
    });

    test('turning OFF stops the buffer BEFORE suspending capture', () {
      final engine = FakeCaptureEngine();
      final result = applyBufferTransition(engine, desired: false);

      expect(engine.calls, ['stop', 'suspendCapture']);
      expect(result, isFalse);
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

    test('a null engine (dev mode, no capture backend) no-ops both ways', () {
      expect(applyBufferTransition(null, desired: true), isFalse);
      expect(applyBufferTransition(null, desired: false), isFalse);
    });
  });
}
