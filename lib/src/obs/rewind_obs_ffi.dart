// FFI bindings to the Rewind C shim. The shim is compiled and bundled by
// hook/build.dart as the code asset `package:rewind/rewind_obs.dart`, so we
// bind via @Native symbols against that default asset — no manual
// DynamicLibrary.open / per-OS library placement needed.
@DefaultAsset('package:rewind/rewind_obs.dart')
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

@Native<Int32 Function(Pointer<Utf8>, Int32)>(symbol: 'rewind_obs_init')
external int _init(Pointer<Utf8> outDir, int seconds);

@Native<Int32 Function()>(symbol: 'rewind_start_buffer')
external int _startBuffer();

@Native<Int32 Function()>(symbol: 'rewind_stop_buffer')
external int _stopBuffer();

@Native<Int32 Function()>(symbol: 'rewind_capture_suspend')
external int _captureSuspend();

@Native<Int32 Function()>(symbol: 'rewind_capture_resume')
external int _captureResume();

@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'rewind_start_recording')
external int _startRecording(Pointer<Utf8> outDir);

@Native<Pointer<Utf8> Function()>(symbol: 'rewind_stop_recording')
external Pointer<Utf8> _stopRecording();

@Native<Int32 Function(Int32)>(symbol: 'rewind_set_buffer_seconds')
external int _setBufferSeconds(int seconds);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(symbol: 'rewind_save_clip')
external Pointer<Utf8> _saveClip(Pointer<Utf8> outDir);

@Native<Int32 Function()>(symbol: 'rewind_obs_shutdown')
external int _shutdown();

@Native<Pointer<Utf8> Function()>(symbol: 'rewind_last_error')
external Pointer<Utf8> _lastError();

@Native<Int32 Function(Pointer<Utf8>, Int32)>(symbol: 'rewind_list_displays')
external int _listDisplays(Pointer<Utf8> jsonOut, int jsonCap);

@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'rewind_set_capture_display')
external int _setCaptureDisplay(Pointer<Utf8> displayUuid);

@Native<Int32 Function(Pointer<Utf8>, Int32)>(
    symbol: 'rewind_list_capturable_apps')
external int _listCapturableApps(Pointer<Utf8> jsonOut, int jsonCap);

@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'rewind_set_capture_app')
external int _setCaptureApp(Pointer<Utf8> bundleId);

@Native<Int32 Function(Uint32)>(symbol: 'rewind_set_capture_window')
external int _setCaptureWindow(int windowId);

@Native<Int32 Function(Int32)>(symbol: 'rewind_set_mic_enabled')
external int _setMicEnabled(int enabled);

@Native<Int32 Function(Pointer<Utf8>, Int32)>(
    symbol: 'rewind_list_audio_inputs_json')
external int _listAudioInputs(Pointer<Utf8> jsonOut, int jsonCap);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'rewind_set_mic_device')
external void _setMicDevice(Pointer<Utf8> uid);

@Native<Int32 Function(Float)>(symbol: 'rewind_set_mic_volume')
external int _setMicVolume(double volume);

@Native<Int32 Function(Int32)>(symbol: 'rewind_set_mic_monitoring')
external int _setMicMonitoring(int enabled);

@Native<Int32 Function(Int32, Int32)>(symbol: 'rewind_set_capture_quality')
external int _setCaptureQuality(int fps, int maxHeight);

@Native<Int32 Function(Int32)>(symbol: 'rewind_set_audio_mode')
external int _setAudioMode(int mode);

@Native<Int32 Function(Float)>(symbol: 'rewind_set_game_volume')
external int _setGameVolume(double volume);

@Native<Int32 Function(Int32)>(symbol: 'rewind_set_mic_leveling')
external int _setMicLeveling(int enabled);

@Native<Int32 Function()>(symbol: 'rewind_preflight_screen_permission')
external int _preflightScreenPermission();

@Native<Int32 Function()>(symbol: 'rewind_request_screen_permission')
external int _requestScreenPermission();

@Native<Int32 Function(Pointer<Utf8>, Int32)>(symbol: 'rewind_perf_stats_json')
external int _perfStatsJson(Pointer<Utf8> jsonOut, int jsonCap);

/// Size of the buffer allocated for `rewind_list_displays`'s JSON
/// out-param. Comfortably covers the display counts Rewind targets (a
/// handful of monitors); the shim reports truncation via a non-zero return
/// rather than silently corrupting output if it's ever exceeded.
const int _kDisplayListBufferSize = 4096;

/// Size of the buffer allocated for `rewind_list_capturable_apps`'s JSON
/// out-param. Larger than [_kDisplayListBufferSize]: a busy desktop can
/// easily have a few dozen apps with on-screen windows, and each entry now
/// carries an absolute .icns icon path on top of the bundle id + name.
const int _kAppListBufferSize = 65536;

/// Size of the buffer allocated for `rewind_perf_stats_json`'s JSON
/// out-param — the object has a fixed, small set of numeric fields, so this
/// comfortably covers it with headroom.
const int _kPerfStatsBufferSize = 512;

/// Size of the buffer allocated for `rewind_list_audio_inputs_json`'s JSON
/// out-param. Mirrors [_kDisplayListBufferSize]: a real machine has at most
/// a handful of microphones (built-in + a few USB/Bluetooth/virtual ones).
const int _kAudioInputListBufferSize = 4096;

/// Thin Dart wrapper over the shim. In pure `dart test` (no native assets
/// built) these calls are never invoked, so tests stay hermetic.
class RewindObs {
  const RewindObs._();

  /// Kept for API compatibility with the previous DynamicLibrary loader.
  /// With native assets the shim is always bundled; returns an instance.
  static RewindObs? tryLoad() => const RewindObs._();

  int init({required String outDir, required int seconds}) {
    final p = outDir.toNativeUtf8();
    try {
      return _init(p, seconds);
    } finally {
      malloc.free(p);
    }
  }

  int startBuffer() => _startBuffer();
  int stopBuffer() => _stopBuffer();

  /// Tears down the capture source, keeping the target preference. See
  /// `rewind_capture_suspend` in native/shim/rewind_obs.h.
  int captureSuspend() => _captureSuspend();

  /// Recreates the capture source from the remembered target preference. See
  /// `rewind_capture_resume` in native/shim/rewind_obs.h.
  int captureResume() => _captureResume();

  /// Starts a manual recording into [outDir]. Returns 0 on success.
  int startRecording(String outDir) {
    final p = outDir.toNativeUtf8();
    try {
      return _startRecording(p);
    } finally {
      malloc.free(p);
    }
  }

  /// Stops the manual recording started by [startRecording], returning the
  /// recorded file's path, or null if none was in progress / on failure.
  String? stopRecording() {
    final r = _stopRecording();
    if (r == nullptr) return null;
    return r.toDartString();
  }

  /// Apply a new replay-buffer length (used on per-game switch).
  int setBufferSeconds(int seconds) => _setBufferSeconds(seconds);

  int shutdown() => _shutdown();

  /// Description of the most recent shim-level failure, or "" if none.
  String lastError() => _lastError().toDartString();

  String? saveClip(String outDir) {
    final p = outDir.toNativeUtf8();
    try {
      final r = _saveClip(p);
      if (r == nullptr) return null;
      return r.toDartString();
    } finally {
      malloc.free(p);
    }
  }

  /// Raw JSON array from `rewind_list_displays`, or null on failure.
  String? listDisplaysJson() {
    final buf = malloc<Uint8>(_kDisplayListBufferSize);
    try {
      final p = buf.cast<Utf8>();
      final r = _listDisplays(p, _kDisplayListBufferSize);
      if (r != 0) return null;
      return p.toDartString();
    } finally {
      malloc.free(buf);
    }
  }

  int setCaptureDisplay(String uuid) {
    final p = uuid.toNativeUtf8();
    try {
      return _setCaptureDisplay(p);
    } finally {
      malloc.free(p);
    }
  }

  /// Raw JSON array from `rewind_list_capturable_apps`, or null on failure.
  String? listCapturableAppsJson() {
    final buf = malloc<Uint8>(_kAppListBufferSize);
    try {
      final p = buf.cast<Utf8>();
      final r = _listCapturableApps(p, _kAppListBufferSize);
      if (r != 0) return null;
      return p.toDartString();
    } finally {
      malloc.free(buf);
    }
  }

  /// Selects an application to capture, or reverts to display capture when
  /// [bundleId] is null.
  int setCaptureApp(String? bundleId) {
    final p = (bundleId ?? '').toNativeUtf8();
    try {
      return _setCaptureApp(p);
    } finally {
      malloc.free(p);
    }
  }

  /// Selects a specific window (CGWindowID) to capture; 0 reverts to the
  /// remaining app/display preference.
  int setCaptureWindow(int windowId) => _setCaptureWindow(windowId);

  /// Enables/disables microphone capture (mixed into clips alongside the
  /// always-on system audio).
  int setMicEnabled(bool enabled) => _setMicEnabled(enabled ? 1 : 0);

  /// Raw JSON array from `rewind_list_audio_inputs_json`, or null on
  /// failure.
  String? listAudioInputsJson() {
    final buf = malloc<Uint8>(_kAudioInputListBufferSize);
    try {
      final p = buf.cast<Utf8>();
      final r = _listAudioInputs(p, _kAudioInputListBufferSize);
      if (r != 0) return null;
      return p.toDartString();
    } finally {
      malloc.free(buf);
    }
  }

  /// Selects the microphone input device, or reverts to the system default
  /// when [uid] is null.
  void setMicDevice(String? uid) {
    final p = (uid ?? '').toNativeUtf8();
    try {
      _setMicDevice(p);
    } finally {
      malloc.free(p);
    }
  }

  /// Sets the microphone recording-level multiplier (1.0 = 100%, clamped by
  /// the shim to 0.0-2.0).
  int setMicVolume(double volume) => _setMicVolume(volume);

  /// Enables/disables live mic monitoring (through the speakers/
  /// headphones) — engine-only, never persisted.
  int setMicMonitoring(bool enabled) => _setMicMonitoring(enabled ? 1 : 0);

  /// Sets capture framerate and output-height cap (0 = source). Applied at
  /// init; call before it.
  int setCaptureQuality(int fps, int maxHeight) =>
      _setCaptureQuality(fps, maxHeight);

  /// Sets the system/app audio mode (0 = off, 1 = all, 2 = app).
  int setAudioMode(int mode) => _setAudioMode(mode);

  /// Sets the game/desktop-audio recording-level multiplier (1.0 = 100%,
  /// clamped by the shim to 0.0-2.0).
  int setGameVolume(double volume) => _setGameVolume(volume);

  /// Enables/disables the mic auto-leveling filter chain
  /// (compressor->limiter).
  int setMicLeveling(bool enabled) => _setMicLeveling(enabled ? 1 : 0);

  /// True if screen-capture permission is currently granted. Safe to poll
  /// repeatedly (e.g. from onboarding UI) — never prompts.
  bool preflightScreenPermission() => _preflightScreenPermission() != 0;

  /// Triggers the OS permission prompt where one exists (a no-op if already
  /// granted, or already asked and denied). Returns the resulting granted
  /// state.
  bool requestScreenPermission() => _requestScreenPermission() != 0;

  /// Raw JSON object from `rewind_perf_stats_json` (CPU/RSS + libobs frame
  /// counters), or null on failure. See [PerfMonitor] (lib/src/log/) for the
  /// periodic sampler that calls this.
  String? perfStatsJson() {
    final buf = malloc<Uint8>(_kPerfStatsBufferSize);
    try {
      final p = buf.cast<Utf8>();
      final r = _perfStatsJson(p, _kPerfStatsBufferSize);
      if (r != 0) return null;
      return p.toDartString();
    } finally {
      malloc.free(buf);
    }
  }
}
