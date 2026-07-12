/// Seam between the coordinator and the capture backend.
///
/// [ClipCoordinator] only ever talks to this interface, never to libobs or
/// the FFI shim directly. This lets tests drive the coordinator with a fake
/// (see `test/fakes/fake_capture_engine.dart`) and keeps the real
/// implementation ([RewindObsEngine], `lib/src/obs/rewind_obs_engine.dart`)
/// swappable.
abstract class CaptureEngine {
  /// Start up the capture backend and begin buffering into [outDir] with a
  /// replay-buffer length of [seconds]. Returns false on failure.
  bool init({required String outDir, required int seconds});

  /// Start the replay buffer. Returns false on failure.
  bool startBuffer();

  /// Stop the replay buffer. Returns false on failure.
  bool stopBuffer();

  /// Change the replay-buffer length while running. Returns false on
  /// failure.
  bool setBufferSeconds(int seconds);

  /// Flush the current buffer to a clip file inside [outDir].
  /// Returns the saved file path, or null on failure.
  String? saveClip(String outDir);

  /// Release all capture resources.
  void shutdown();

  /// Human-readable description of the most recent failure, or an empty
  /// string if the last operation succeeded.
  String get lastError;
}
