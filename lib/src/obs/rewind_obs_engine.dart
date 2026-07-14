import '../log/log.dart';
import 'app_info.dart';
import 'capture_engine.dart';
import 'display_info.dart';
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
  bool startRecording(String outDir) => _obs.startRecording(outDir) == 0;
  @override
  String? stopRecording() => _obs.stopRecording();

  @override
  void shutdown() => _obs.shutdown();
  @override
  String get lastError => _obs.lastError();

  @override
  List<DisplayInfo> listDisplays() {
    final json = _obs.listDisplaysJson();
    if (json == null) {
      talker.warning('listDisplays failed: ${_obs.lastError()}');
      return const [];
    }
    try {
      return DisplayInfo.listFromJson(json);
    } catch (err, stack) {
      talker.handle(err, stack);
      return const [];
    }
  }

  @override
  bool setCaptureDisplay(String uuid) => _obs.setCaptureDisplay(uuid) == 0;

  @override
  List<AppInfo> listCapturableApps() {
    final json = _obs.listCapturableAppsJson();
    if (json == null) {
      talker.warning('listCapturableApps failed: ${_obs.lastError()}');
      return const [];
    }
    try {
      return AppInfo.listFromJson(json);
    } catch (err, stack) {
      talker.handle(err, stack);
      return const [];
    }
  }

  @override
  bool setCaptureApp(String? bundleId) => _obs.setCaptureApp(bundleId) == 0;
}
