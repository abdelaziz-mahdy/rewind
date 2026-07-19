import 'dart:async';
import 'dart:io';

import '../log/log.dart';

/// Short audible feedback for MANUAL save/record actions only — see
/// `ClipCoordinator`'s `sounds` field and `AppSettings.playFeedbackSounds`.
/// Auto-clipped events never call this: a mid-teamfight chime for a save the
/// user didn't trigger would be noise, not feedback.
abstract class ClipSounds {
  /// A manual save (hotkey or `.save-now`) completed successfully.
  void saveSucceeded();

  /// A manual save resolved with an error (buffer paused, disk full, etc.).
  void saveFailed();

  /// A manual recording session (hotkey or `.record-toggle`) started.
  void recordingStarted();

  /// A manual recording session stopped and was saved.
  void recordingStopped();
}

/// macOS implementation: fires one of four stock `/System/Library/Sounds`
/// AIFFs via `afplay`, fire-and-forget. Zero bundled assets — reusing the
/// system's own sounds gives native-feeling feedback without shipping audio.
///
/// Every call is deliberately synchronous-looking but never awaited
/// internally into a save path: `afplay` is spawned and its result ignored,
/// so a slow/missing binary can never delay or fail a save. All errors
/// (missing file, spawn failure) are swallowed — this is pure feedback, not
/// something a save should ever depend on.
///
/// Windows/Linux: no-op for now. Future recipes: Windows can shell out to
/// `powershell -c [System.Media.SystemSounds]::Asterisk.Play()` (or similar
/// per sound); Linux can use `paplay` against a freedesktop sound theme.
/// Neither is implemented yet, so [saveSucceeded] et al. simply do nothing
/// on those platforms.
class SystemClipSounds implements ClipSounds {
  static const _saveSucceededPath = '/System/Library/Sounds/Glass.aiff';
  static const _saveFailedPath = '/System/Library/Sounds/Basso.aiff';
  static const _recordingStartedPath = '/System/Library/Sounds/Tink.aiff';
  static const _recordingStoppedPath = '/System/Library/Sounds/Pop.aiff';

  @override
  void saveSucceeded() => _play(_saveSucceededPath);

  @override
  void saveFailed() => _play(_saveFailedPath);

  @override
  void recordingStarted() => _play(_recordingStartedPath);

  @override
  void recordingStopped() => _play(_recordingStoppedPath);

  void _play(String path) {
    if (!Platform.isMacOS) return; // Windows/Linux: no-op (see class doc).
    unawaited(_playAsync(path));
  }

  Future<void> _playAsync(String path) async {
    try {
      if (!await File(path).exists()) return;
      await Process.run('afplay', [path]);
    } catch (err, stack) {
      // Feedback sounds must never surface as a user-facing error.
      talker.handle(err, stack);
    }
  }
}
