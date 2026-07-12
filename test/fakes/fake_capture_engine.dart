import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:rewind/src/obs/capture_engine.dart';

class FakeCaptureEngine implements CaptureEngine {
  final List<String> calls = [];
  bool failSave = false;

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
    return f.path;
  }

  @override
  void shutdown() => calls.add('shutdown');
  @override
  String get lastError => failSave ? 'fake save failure' : '';
}
