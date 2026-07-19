import 'capture_engine.dart';

/// The exact [CaptureEngine] call sequence a buffer-active transition must
/// make. Extracted out of `main.dart`'s `applyBufferPolicy` — the app's
/// single buffer-control point — purely so the ordering below is directly
/// testable against `FakeCaptureEngine`'s call log (`applyBufferPolicy`
/// itself lives inside `main()` and isn't otherwise reachable from a test).
/// `applyBufferPolicy` still owns every decision about *when* to call this:
/// the desired-vs-current comparison and the tray/`bufferAutoPaused` side
/// effects stay there.
///
/// OFF ([desired] `false`): stop the replay buffer FIRST, then suspend the
/// capture session ([CaptureEngine.suspendCapture], backed by
/// `rewind_capture_suspend` — see `native/shim/rewind_obs.h`) so nothing
/// keeps producing frames — or holding the macOS screen-recording indicator
/// — while paused.
///
/// ON ([desired] `true`): resume the capture session
/// ([CaptureEngine.resumeCapture]) BEFORE starting the buffer — starting the
/// buffer against a torn-down capture source would begin recording a black/
/// empty replay until the source finishes rebuilding.
///
/// Returns the resulting buffer-active state: whatever `startBuffer()`
/// reports on ON, always `false` on OFF. A null [engine] (dev mode, no
/// capture backend) no-ops safely in both directions.
bool applyBufferTransition(CaptureEngine? engine, {required bool desired}) {
  if (desired) {
    engine?.resumeCapture();
    return engine?.startBuffer() ?? false;
  }
  engine?.stopBuffer();
  engine?.suspendCapture();
  return false;
}
