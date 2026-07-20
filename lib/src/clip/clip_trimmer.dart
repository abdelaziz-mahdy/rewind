import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Exports a time range of an existing clip file to a NEW file, leaving the
/// original untouched — the player's trim feature. Seam so tests fake the
/// export (real trimming needs a native media framework) and so platforms
/// grow support independently.
abstract class ClipTrimmer {
  /// Whether this platform can trim at all — gates the player's Trim
  /// button, so unsupported platforms simply don't show the affordance
  /// rather than failing on use.
  bool get isSupported;

  /// Writes `[start, end)` of the clip at [srcPath] to [outPath]. Returns
  /// true on success; false on any failure (unsupported platform, missing
  /// source, export error). Never throws.
  Future<bool> trim({
    required String srcPath,
    required Duration start,
    required Duration end,
    required String outPath,
  });
}

/// The output path for a trim of [srcPath]: same directory, the source's
/// base name plus a `-trim-N` suffix that doesn't collide with [taken]
/// (existing library paths). Pure so tests pin the naming.
String trimOutPath(String srcPath, Iterable<String> taken) {
  final dot = srcPath.lastIndexOf('.');
  final base = dot > srcPath.lastIndexOf('/') ? srcPath.substring(0, dot) : srcPath;
  final ext = dot > srcPath.lastIndexOf('/') ? srcPath.substring(dot) : '.mp4';
  final existing = taken.toSet();
  for (var n = 1;; n++) {
    final candidate = '$base-trim-$n$ext';
    if (!existing.contains(candidate)) return candidate;
  }
}

/// macOS implementation over a small MethodChannel handled in the Runner
/// (AVAssetExportSession with the passthrough preset — stream copy, no
/// re-encode, so it's fast and lossless; the cut lands on the nearest
/// keyframes, which for Rewind's short-GOP game encodes is within a
/// second). Windows/Linux report unsupported for now; the Trim button
/// hides there (see `PlayerScreen`).
class MethodChannelClipTrimmer implements ClipTrimmer {
  static const _channel = MethodChannel('rewind/clip_trimmer');

  @override
  bool get isSupported => Platform.isMacOS;

  @override
  Future<bool> trim({
    required String srcPath,
    required Duration start,
    required Duration end,
    required String outPath,
  }) async {
    if (!isSupported) return false;
    if (end <= start) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('trim', <String, Object>{
        'src': srcPath,
        'out': outPath,
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
      });
      return ok == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // An older Runner build without the handler — behave as unsupported
      // rather than crashing the save.
      return false;
    }
  }
}
