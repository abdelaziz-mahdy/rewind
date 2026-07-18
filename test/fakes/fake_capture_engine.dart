import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/obs/capture_engine.dart';
import 'package:rewind/src/obs/display_info.dart';

class FakeCaptureEngine implements CaptureEngine {
  final List<String> calls = [];
  bool failSave = false;

  /// Two fake displays, mirroring what a real multi-monitor setup would
  /// report from `rewind_list_displays`.
  final List<DisplayInfo> displays = const [
    DisplayInfo(uuid: 'display-1', width: 1920, height: 1080, isMain: true),
    DisplayInfo(uuid: 'display-2', width: 2560, height: 1440, isMain: false),
  ];

  /// Every uuid passed to [setCaptureDisplay], in call order.
  final List<String> captureDisplayCalls = [];

  /// Two fake apps, mirroring what a real desktop's on-screen windows would
  /// report from `rewind_list_capturable_apps`. Mutable so tests can add
  /// e.g. a Wine app (empty bundleId) to the enumeration.
  List<AppInfo> apps = const [
    AppInfo(bundleId: 'com.rewind.stub.one', name: 'Stub App One', pid: 1001),
    AppInfo(bundleId: 'com.rewind.stub.two', name: 'Stub App Two', pid: 1002),
  ];

  /// Every bundle id passed to [setCaptureApp], in call order (null entries
  /// record a revert-to-display call).
  final List<String?> captureAppCalls = [];

  /// Every window id passed to [setCaptureWindow], in call order.
  final List<int> captureWindowCalls = [];

  /// When false, [saveClip] reports a path but writes no file — mimics the
  /// C shim's stub mode, which the coordinator must not index.
  bool writeFile = true;
  int? lastBufferSeconds;
  int _n = 0;

  @override
  bool init({required String outDir, required int seconds}) {
    calls.add('init:$seconds');
    lastBufferSeconds = seconds;
    return true;
  }

  @override
  bool startBuffer() {
    calls.add('start');
    return true;
  }

  @override
  bool stopBuffer() {
    calls.add('stop');
    return true;
  }

  @override
  bool setBufferSeconds(int seconds) {
    calls.add('setBuffer:$seconds');
    lastBufferSeconds = seconds;
    return true;
  }

  /// Path returned by the most recent [saveClip] call — lets a test write
  /// the file late itself (mux-lag simulation).
  String? lastSavedPath;

  @override
  String? saveClip(String outDir) {
    calls.add('save');
    if (failSave) return null;
    final f = File(p.join(outDir, 'clip-${_n++}.mp4'));
    if (writeFile) {
      f
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(16, 0));
    }
    lastSavedPath = f.path;
    return f.path;
  }

  /// When true, [startRecording]/[stopRecording] fail like the shim would.
  bool failRecording = false;
  bool _recording = false;
  String? _recordingDir;
  bool get isRecording => _recording;

  @override
  bool startRecording(String outDir) {
    calls.add('startRecording');
    if (failRecording || _recording) return false;
    _recording = true;
    _recordingDir = outDir;
    return true;
  }

  @override
  String? stopRecording() {
    calls.add('stopRecording');
    if (failRecording || !_recording) return null;
    _recording = false;
    final f = File(p.join(_recordingDir ?? '.', 'recording-${_n++}.mp4'));
    if (writeFile) {
      f
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(32, 0));
    }
    return f.path;
  }

  @override
  void shutdown() => calls.add('shutdown');
  @override
  String get lastError => failSave ? 'fake save failure' : '';

  @override
  List<DisplayInfo> listDisplays() {
    calls.add('listDisplays');
    return displays;
  }

  @override
  bool setCaptureDisplay(String uuid) {
    calls.add('setCaptureDisplay:$uuid');
    captureDisplayCalls.add(uuid);
    return true;
  }

  @override
  List<AppInfo> listCapturableApps() {
    calls.add('listCapturableApps');
    return apps;
  }

  @override
  bool setCaptureApp(String? bundleId) {
    calls.add('setCaptureApp:${bundleId ?? 'null'}');
    captureAppCalls.add(bundleId);
    return true;
  }

  @override
  bool setCaptureWindow(int windowId) {
    calls.add('setCaptureWindow:$windowId');
    captureWindowCalls.add(windowId);
    return true;
  }

  @override
  bool setMicEnabled(bool enabled) {
    calls.add('setMic:$enabled');
    micEnabled = enabled;
    return true;
  }

  /// Last value passed to [setMicEnabled].
  bool? micEnabled;

  @override
  bool setCaptureQuality(int fps, int maxHeight) {
    calls.add('setCaptureQuality:$fps:$maxHeight');
    return true;
  }

  @override
  bool setAudioMode(int mode) {
    calls.add('setAudioMode:$mode');
    audioMode = mode;
    return true;
  }

  /// Last value passed to [setAudioMode].
  int? audioMode;

  /// Settable current screen-capture permission state, mirroring the real
  /// engine's live/pollable grant state — tests flip this directly to
  /// simulate a grant happening in System Settings while the app runs.
  bool screenPermissionGranted = true;

  @override
  bool preflightScreenPermission() {
    calls.add('preflightScreenPermission');
    return screenPermissionGranted;
  }

  @override
  bool requestScreenPermission() {
    calls.add('requestScreenPermission');
    return screenPermissionGranted;
  }
}
