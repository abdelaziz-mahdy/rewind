import 'app_info.dart';
import 'display_info.dart';

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

  /// Begin a manual recording session into [outDir]: unlike the rolling
  /// replay buffer, this records continuously from now until
  /// [stopRecording], sharing the same capture source and encoders. The
  /// replay buffer keeps running independently. Returns false on failure
  /// (including when a recording is already in progress).
  bool startRecording(String outDir);

  /// End the manual recording session started by [startRecording].
  /// Returns the recorded file's path, or null on failure / when no
  /// recording is in progress.
  String? stopRecording();

  /// Release all capture resources.
  void shutdown();

  /// Enumerate the connected displays. Safe to call before [init]. Returns
  /// an empty list if enumeration fails (see [lastError]).
  List<DisplayInfo> listDisplays();

  /// Select which display the capture source should record, identified by
  /// a [DisplayInfo.uuid] from [listDisplays]. Safe to call before [init]
  /// (the preference is remembered and applied at init); if the capture
  /// source is already running, it is reconfigured immediately. Returns
  /// false on failure.
  bool setCaptureDisplay(String uuid);

  /// Enumerate applications that currently have at least one capturable
  /// on-screen window. Safe to call before [init]. Returns an empty list
  /// if enumeration fails (see [lastError]).
  List<AppInfo> listCapturableApps();

  /// Select a specific application to capture instead of a whole display,
  /// identified by an [AppInfo.bundleId] from [listCapturableApps]. Safe
  /// to call before [init] (the preference is remembered and applied at
  /// init — an app target takes precedence over a display target if both
  /// are set); if the capture source is already running, it is
  /// reconfigured immediately. Passing `null` reverts to display capture.
  /// Returns false on failure.
  bool setCaptureApp(String? bundleId);

  /// Select a specific window to capture, identified by an
  /// [AppInfo.windowId] from [listCapturableApps] — the only way to capture
  /// a CrossOver/Wine game (no bundle id exists for [setCaptureApp] to
  /// match). Window ids are EPHEMERAL: never persist one; re-resolve from a
  /// fresh [listCapturableApps] instead. Passing 0 — or any later
  /// [setCaptureApp] call — reverts to the app/display preference. Returns
  /// false on failure.
  bool setCaptureWindow(int windowId);

  /// Enable/disable microphone capture (default input device), mixed into
  /// every clip and recording alongside the always-on system audio. Safe to
  /// call before [init] (the preference is applied at init). First use
  /// triggers the macOS microphone permission prompt. Returns false on
  /// failure.
  bool setMicEnabled(bool enabled);

  /// Set capture framerate ([fps], e.g. 30 or 60) and output-height cap
  /// ([maxHeight], 0 = source resolution). Applied at [init] — call before
  /// it; after init it only stores the values (a resolution/fps change needs
  /// a fresh capture pipeline, so it takes effect on next launch). Returns
  /// false on failure.
  bool setCaptureQuality(int fps, int maxHeight);

  /// Set the system/app audio mode: 0 = none (silent), 1 = all desktop
  /// audio, 2 = only the captured app's audio (see `AudioMode`). App mode
  /// needs an app/window capture source. Safe before or after [init]
  /// (rebuilds live). Returns false on failure.
  bool setAudioMode(int mode);

  /// Human-readable description of the most recent failure, or an empty
  /// string if the last operation succeeded.
  String get lastError;
}
