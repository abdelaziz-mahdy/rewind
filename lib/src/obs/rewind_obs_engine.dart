import 'capture_engine.dart';
import 'rewind_obs_ffi.dart';

/// [CaptureEngine] backed by the C shim (libobs or stub) via dart:ffi.
class RewindObsEngine implements CaptureEngine {
  final RewindObs _obs;
  RewindObsEngine([RewindObs? obs]) : _obs = obs ?? RewindObs.tryLoad()!;

  @override
  bool init({required String outDir, required int seconds}) =>
      _obs.init(outDir: outDir, seconds: seconds) == 0;
  @override
  bool startBuffer() => _obs.startBuffer() == 0;
  @override
  bool stopBuffer() => _obs.stopBuffer() == 0;
  @override
  bool setBufferSeconds(int seconds) => _obs.setBufferSeconds(seconds) == 0;
  @override
  String? saveClip(String outDir) => _obs.saveClip(outDir);
  @override
  void shutdown() => _obs.shutdown();
  @override
  String get lastError => _obs.lastError();
}
