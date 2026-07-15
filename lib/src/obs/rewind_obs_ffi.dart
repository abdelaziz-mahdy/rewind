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
}
