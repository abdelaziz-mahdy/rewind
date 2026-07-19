import 'package:rewind/src/sound/clip_sounds.dart';

/// Records every call in order — never plays anything. Tests assert on
/// [calls] instead of shelling out to `afplay`/exercising real audio.
class FakeClipSounds implements ClipSounds {
  final List<String> calls = [];

  @override
  void saveSucceeded() => calls.add('saveSucceeded');

  @override
  void saveFailed() => calls.add('saveFailed');

  @override
  void recordingStarted() => calls.add('recordingStarted');

  @override
  void recordingStopped() => calls.add('recordingStopped');
}
