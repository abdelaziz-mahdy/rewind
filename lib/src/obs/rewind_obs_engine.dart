import '../log/log.dart';
import 'app_info.dart';
import 'audio_input_info.dart';
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

  @override
  bool setCaptureWindow(int windowId) => _obs.setCaptureWindow(windowId) == 0;

  @override
  bool setMicEnabled(bool enabled) => _obs.setMicEnabled(enabled) == 0;

  @override
  List<AudioInputInfo> listAudioInputs() {
    final json = _obs.listAudioInputsJson();
    if (json == null) {
      talker.warning('listAudioInputs failed: ${_obs.lastError()}');
      return const [];
    }
    try {
      return AudioInputInfo.listFromJson(json);
    } catch (err, stack) {
      talker.handle(err, stack);
      return const [];
    }
  }

  @override
  void setMicDevice(String? uid) => _obs.setMicDevice(uid);

  @override
  bool setMicVolume(double volume) => _obs.setMicVolume(volume) == 0;

  @override
  bool setMicMonitoring(bool enabled) => _obs.setMicMonitoring(enabled) == 0;

  @override
  bool setCaptureQuality(int fps, int maxHeight) =>
      _obs.setCaptureQuality(fps, maxHeight) == 0;

  @override
  bool setAudioMode(int mode) => _obs.setAudioMode(mode) == 0;

  @override
  bool setGameVolume(double volume) => _obs.setGameVolume(volume) == 0;

  @override
  bool setMicLeveling(bool enabled) => _obs.setMicLeveling(enabled) == 0;

  @override
  bool preflightScreenPermission() => _obs.preflightScreenPermission();

  @override
  bool requestScreenPermission() => _obs.requestScreenPermission();

  @override
  String? perfStatsJson() => _obs.perfStatsJson();
}
