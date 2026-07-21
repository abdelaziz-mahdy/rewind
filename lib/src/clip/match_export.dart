import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../log/log.dart';
import 'clip.dart';

/// Exports one continuous video from all of a match's clips — "share the
/// full match" without touching the individual clips. Seam so tests fake it
/// (the real one needs the bundled FFmpeg binaries).
abstract class MatchExporter {
  /// Same platform gate as trimming: macOS + Windows while ffmpeg_kit
  /// ships no Linux binaries.
  bool get isSupported;

  /// Concatenates [clips] (already in playback order) into [outPath].
  /// Returns true on success. Never throws.
  Future<bool> export(List<Clip> clips, String outPath);
}

/// The ffconcat list-file body for [paths]. Rewind's clips all come from
/// the same encoder settings, so the concat DEMUXER with stream copy works
/// without re-encoding. Single quotes in paths are escaped per ffmpeg's
/// quoting rules. Pure so tests pin the format.
String concatListBody(Iterable<String> paths) {
  final b = StringBuffer('ffconcat version 1.0\n');
  for (final p in paths) {
    b.writeln("file '${p.replaceAll("'", r"'\''")}'");
  }
  return b.toString();
}

/// The FFmpeg argument list for a concat export from a written list file.
/// Pure so tests pin the exact command.
List<String> concatArguments(String listPath, String outPath) => [
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listPath,
      '-c',
      'copy',
      '-y',
      outPath,
    ];

/// The export file name for a match: derived from the first clip's file
/// name with a `-full-match` suffix, collision-bumped against [taken].
String matchExportPath(Clip first, Iterable<String> taken) {
  final src = first.path;
  final dot = src.lastIndexOf('.');
  final base = dot > src.lastIndexOf('/') ? src.substring(0, dot) : src;
  final ext = dot > src.lastIndexOf('/') ? src.substring(dot) : '.mp4';
  final existing = taken.toSet();
  var candidate = '$base-full-match$ext';
  for (var n = 2; existing.contains(candidate); n++) {
    candidate = '$base-full-match-$n$ext';
  }
  return candidate;
}

/// FFmpeg-backed [MatchExporter] (`ffmpeg_kit_flutter_new`, same package
/// as trim/thumbnails/filmstrip).
class FfmpegMatchExporter implements MatchExporter {
  @override
  bool get isSupported => Platform.isMacOS || Platform.isWindows;

  @override
  Future<bool> export(List<Clip> clips, String outPath) async {
    if (!isSupported || clips.isEmpty) return false;
    File? listFile;
    try {
      listFile = File(
          '${Directory.systemTemp.path}/rewind-concat-${DateTime.now().millisecondsSinceEpoch}.txt');
      await listFile.writeAsString(concatListBody(clips.map((c) => c.path)));
      final session = await FFmpegKit.executeWithArguments(
          concatArguments(listFile.path, outPath));
      final ok = ReturnCode.isSuccess(await session.getReturnCode());
      if (!ok) {
        talker.warning('Match export: ffmpeg concat failed for $outPath');
        return false;
      }
      return await File(outPath).exists();
    } catch (err, stack) {
      talker.handle(err, stack);
      return false;
    } finally {
      // Best-effort scratch cleanup; a leaked tiny list file in temp is
      // not worth failing an export over.
      try {
        await listFile?.delete();
      } on FileSystemException {
        // ignore
      }
    }
  }
}
