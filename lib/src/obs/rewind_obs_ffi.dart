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

@Native<Int32 Function(Int32)>(symbol: 'rewind_set_buffer_seconds')
external int _setBufferSeconds(int seconds);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(symbol: 'rewind_save_clip')
external Pointer<Utf8> _saveClip(Pointer<Utf8> outDir);

@Native<Int32 Function()>(symbol: 'rewind_obs_shutdown')
external int _shutdown();

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

  /// Apply a new replay-buffer length (used on per-game switch).
  int setBufferSeconds(int seconds) => _setBufferSeconds(seconds);

  int shutdown() => _shutdown();

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
}
