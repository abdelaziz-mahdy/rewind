import 'app_info.dart';
import 'audio_input_info.dart';
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

  /// Suspends the capture session: tears down the underlying screen/window
  /// capture source (releasing it — not merely hiding it) while remembering
  /// every stored target preference (display/app/window), so [resumeCapture]
  /// recreates the identical source. On macOS this is what actually stops
  /// the ScreenCaptureKit stream — see `rewind_capture_suspend` in
  /// `native/shim/rewind_obs.h` — clearing the OS screen-recording indicator
  /// and letting DRM-protected video play again while Rewind idles. Meant to
  /// be called right after [stopBuffer] on every buffer-stop (auto-pause OR
  /// a manual tray pause) — see `main.dart`'s `applyBufferPolicy`. Idempotent
  /// (suspending an already-suspended session is a no-op); a no-op backend
  /// no-op too (dev/stub mode). Returns false on failure.
  bool suspendCapture();

  /// Reverses [suspendCapture]: recreates the capture source from the
  /// remembered display/app/window preference and re-attaches it. Meant to
  /// be called BEFORE [startBuffer] whenever the buffer is about to resume —
  /// starting the buffer against a torn-down source would begin recording a
  /// black/empty replay. [startRecording] also resumes implicitly if the
  /// session is currently suspended. Idempotent (resuming an already-live
  /// session is a no-op). Returns false on failure.
  bool resumeCapture();

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

  /// Enumerate audio INPUT devices (microphones). Safe to call before
  /// [init]. Returns an empty list if enumeration failed, or on a platform
  /// where it isn't implemented yet (Windows/Linux currently — see
  /// `rewind_list_audio_inputs_json` in native/shim/rewind_obs.h); the
  /// Settings picker hides itself entirely when this is empty rather than
  /// showing a fake device list.
  List<AudioInputInfo> listAudioInputs();

  /// Select the microphone input device, identified by an
  /// [AudioInputInfo.uid] from [listAudioInputs], or `null` for the system
  /// default. Safe to call before [init] (the preference is remembered and
  /// applied whenever the mic source is next built); if the mic is already
  /// live, it is rebuilt on the new device immediately.
  void setMicDevice(String? uid);

  /// Set the microphone recording-level multiplier (1.0 = 100%, clamped to
  /// 0.0-2.0). Safe to call before [init] (the preference is remembered and
  /// applied whenever the mic source is next built); if the mic is already
  /// live, the level changes immediately. Returns false on failure.
  bool setMicVolume(double volume);

  /// Monitors the microphone live through the speakers/headphones while
  /// tuning its level — engine-only, transient state (never persisted, see
  /// `AppSettings`). A no-op with no mic source live (mic capture off, or
  /// [init] not yet called): the setting is still remembered and applied the
  /// next time one is built. Returns false on failure.
  bool setMicMonitoring(bool enabled);

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

  /// Set the game/desktop-audio recording-level multiplier (1.0 = 100%,
  /// clamped to 0.0-2.0) — the same lever as [setMicVolume] but against the
  /// desktop-audio source, letting the user pull game audio down under
  /// their voice. Safe to call before [init] (the preference is remembered
  /// and applied whenever the desktop-audio source is next built); if it's
  /// already live, the level changes immediately. Returns false on failure.
  bool setGameVolume(double volume);

  /// Enable/disable mic auto-leveling: a compressor->limiter filter chain
  /// on the microphone source that evens out voice so it sits consistently
  /// against the game, default ON. Safe to call before [init] (the
  /// preference is remembered and applied whenever the mic source is next
  /// built, same as [setMicVolume]); if the mic is already live, the
  /// filters are attached/removed immediately. Returns false on failure.
  bool setMicLeveling(bool enabled);

  /// Human-readable description of the most recent failure, or an empty
  /// string if the last operation succeeded.
  String get lastError;

  /// True if screen-capture permission is currently granted. Safe to poll
  /// repeatedly (e.g. once a second from onboarding UI) to detect a grant
  /// that happened in System Settings while the app is running — never
  /// prompts. Always true on platforms with no equivalent OS gate.
  bool preflightScreenPermission();

  /// Triggers the OS permission prompt where one exists (a no-op if already
  /// granted, or already asked and denied — the user must be sent to System
  /// Settings instead in that case). Returns the resulting granted state,
  /// same as [preflightScreenPermission].
  bool requestScreenPermission();

  /// Compact JSON snapshot of this process's own CPU/memory usage plus
  /// libobs's frame-health counters (see `rewind_perf_stats_json` in
  /// native/shim/rewind_obs.h), or null on failure. Sampled periodically by
  /// `PerfMonitor` (lib/src/log/perf_monitor.dart) — cheap enough to poll
  /// often, but not meant to be called on a hot path.
  String? perfStatsJson();
}
