import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Dart FFI bindings to the Rewind C shim (native/shim/rewind_obs.c).
///
/// The shim is intentionally tiny; all libobs complexity lives on the C side.
/// This is a scaffold — the native library is loaded lazily and calls are
/// no-ops until the shim is linked against a real libobs build.
typedef _InitNative = Int32 Function(Pointer<Utf8> outDir, Int32 seconds);
typedef _InitDart = int Function(Pointer<Utf8> outDir, int seconds);

typedef _VoidRetInt = Int32 Function();
typedef _VoidRetIntDart = int Function();

typedef _SaveNative = Pointer<Utf8> Function(Pointer<Utf8> outDir);
typedef _SaveDart = Pointer<Utf8> Function(Pointer<Utf8> outDir);

class RewindObs {
  final DynamicLibrary _lib;

  late final _InitDart _init =
      _lib.lookupFunction<_InitNative, _InitDart>('rewind_obs_init');
  late final _VoidRetIntDart _startBuffer =
      _lib.lookupFunction<_VoidRetInt, _VoidRetIntDart>('rewind_start_buffer');
  late final _VoidRetIntDart _stopBuffer =
      _lib.lookupFunction<_VoidRetInt, _VoidRetIntDart>('rewind_stop_buffer');
  late final _SaveDart _saveClip =
      _lib.lookupFunction<_SaveNative, _SaveDart>('rewind_save_clip');
  late final _VoidRetIntDart _shutdown =
      _lib.lookupFunction<_VoidRetInt, _VoidRetIntDart>('rewind_obs_shutdown');

  RewindObs._(this._lib);

  /// Load the platform shim library. Returns null if not present (dev mode).
  static RewindObs? tryLoad() {
    try {
      return RewindObs._(DynamicLibrary.open(_libName()));
    } catch (_) {
      return null; // shim not built yet — app runs in no-capture dev mode
    }
  }

  static String _libName() {
    if (Platform.isMacOS) return 'librewind_obs.dylib';
    if (Platform.isWindows) return 'rewind_obs.dll';
    return 'librewind_obs.so';
  }

  /// Initialise libobs and configure a [seconds]-long replay buffer.
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
  int shutdown() => _shutdown();

  /// Flush the last N seconds to [outDir]; returns the written file path.
  String? saveClip(String outDir) {
    final p = outDir.toNativeUtf8();
    try {
      final result = _saveClip(p);
      if (result == nullptr) return null;
      return result.toDartString();
    } finally {
      malloc.free(p);
    }
  }
}
