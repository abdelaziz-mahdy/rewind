import 'dart:io' show Platform;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

/// Exports a time range of an existing clip file to a NEW file, leaving the
/// original untouched — the player's trim feature. Seam so tests fake the
/// export (the real one shells into FFmpeg) and so platforms grow support
/// independently.
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
  final base =
      dot > srcPath.lastIndexOf('/') ? srcPath.substring(0, dot) : srcPath;
  final ext =
      dot > srcPath.lastIndexOf('/') ? srcPath.substring(dot) : '.mp4';
  final existing = taken.toSet();
  for (var n = 1;; n++) {
    final candidate = '$base-trim-$n$ext';
    if (!existing.contains(candidate)) return candidate;
  }
}

/// FFmpeg's `-ss/-t` arguments want seconds; fractional so a mid-second
/// handle position isn't silently rounded a full second off.
String ffmpegSeconds(Duration d) =>
    (d.inMilliseconds / 1000).toStringAsFixed(3);

/// The FFmpeg argument list for a lossless range export: input-seek to the
/// keyframe at/before [start] (`-ss` BEFORE `-i` — fast, no decode), copy
/// [end]-[start] worth of stream (`-c copy`, no re-encode), timestamps
/// re-zeroed so players don't show a gap at the front. Pure so tests pin
/// the exact command without running FFmpeg.
List<String> trimArguments({
  required String srcPath,
  required Duration start,
  required Duration end,
  required String outPath,
}) =>
    [
      '-ss', ffmpegSeconds(start),
      '-i', srcPath,
      '-t', ffmpegSeconds(end - start),
      '-c', 'copy',
      '-avoid_negative_ts', 'make_zero',
      '-y', outPath,
    ];

/// Real trimmer over `ffmpeg_kit_flutter_new` (bundled FFmpeg — the same
/// tool the mpv/OBS world shells out to for cutting; stream copy keeps it
/// fast and lossless, with the cut landing on the keyframe at/before the
/// requested start). Supported where the package ships desktop binaries:
/// macOS and Windows x86_64; Linux hides the Trim button until the package
/// (or a successor) grows support.
class FfmpegKitClipTrimmer implements ClipTrimmer {
  @override
  bool get isSupported => Platform.isMacOS || Platform.isWindows;

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
      final session = await FFmpegKit.executeWithArguments(trimArguments(
        srcPath: srcPath,
        start: start,
        end: end,
        outPath: outPath,
      ));
      return ReturnCode.isSuccess(await session.getReturnCode());
    } catch (_) {
      // Missing platform binaries / plugin not registered — behave as a
      // failed trim (the UI reports it), never crash the player.
      return false;
    }
  }
}
