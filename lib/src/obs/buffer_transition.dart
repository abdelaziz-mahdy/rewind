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
/// The outcome of one transition, so callers can LOG what actually happened
/// rather than assuming it worked. Every step here can fail independently —
/// and when suspend fails, the capture source keeps running: macOS goes on
/// showing its screen-recording indicator and the CPU/GPU cost the pause was
/// supposed to save is still being paid, with nothing on screen or in the log
/// to say so.
typedef BufferTransition = ({bool active, bool sourceOk, bool bufferOk});

BufferTransition applyBufferTransition(CaptureEngine? engine,
    {required bool desired}) {
  if (desired) {
    final sourceOk = engine?.resumeCapture() ?? true;
    final bufferOk = engine?.startBuffer() ?? false;
    return (active: bufferOk, sourceOk: sourceOk, bufferOk: bufferOk);
  }
  final bufferOk = engine?.stopBuffer() ?? true;
  final sourceOk = engine?.suspendCapture() ?? true;
  return (active: false, sourceOk: sourceOk, bufferOk: bufferOk);
}
