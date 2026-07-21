import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../obs/app_info.dart';
import 'exe_icon_extractor.dart';

/// Resolves the real icon for a running non-Steam Windows/Wine game by
/// reading it out of the game's own `.exe` (see [pngIconFromPeBytes]) and
/// caching a PNG. This is the fallback after the Steam library lookup misses
/// — an itch/Epic/standalone game run through CrossOver has no macOS bundle
/// icon and no Steam art, but the icon is embedded in its executable.
///
/// Pure Dart: it finds the running exe's path from the process list, maps a
/// Windows `C:\…` path into its CrossOver bottle, reads the bytes, and parses
/// the icon. Async + memoized; never throws (any failure → null → monogram).
class ExeIconResolver {
  /// Where resolved icons are cached (one PNG per exe).
  final Directory cacheDir;

  /// Returns the CrossOver `drive_c` directories a Windows `C:\…` path can be
  /// resolved into. Injectable for tests; defaults to every bottle's drive_c.
  final List<Directory> Function() bottleDriveCs;

  /// Resolves a pid to its executable path (a Windows `C:\…\Game.exe` for a
  /// Wine process, or a real path). Injectable; defaults to `ps`.
  final Future<String?> Function(int pid) exePathForPid;

  /// Skip executables larger than this — the icon isn't worth reading a
  /// pathologically huge file into memory. Real game exes sit well under it.
  static const _maxExeBytes = 300 * 1024 * 1024;

  ExeIconResolver({
    required this.cacheDir,
    List<Directory> Function()? bottleDriveCs,
    Future<String?> Function(int pid)? exePathForPid,
  })  : bottleDriveCs = bottleDriveCs ?? _defaultBottleDriveCs,
        exePathForPid = exePathForPid ?? _psExePathForPid;

  final Map<String, Future<String?>> _byKey = {};

  /// The cached icon PNG path for [app], resolving (and reading its exe) at
  /// most once per app name per session. Null when the app isn't a resolvable
  /// Windows/Wine exe or carries no PNG icon.
  Future<String?> iconForApp(AppInfo app) {
    // Only Wine/CrossOver apps (empty bundle id) route through the exe reader;
    // a normal macOS app already has its bundle .icns.
    if (app.bundleId.isNotEmpty) return Future.value(null);
    return _byKey.putIfAbsent(app.name, () => _resolve(app));
  }

  Future<String?> _resolve(AppInfo app) async {
    try {
      final exePath = await exePathForPid(app.pid);
      if (exePath == null || exePath.isEmpty) return null;
      final real = _realPathFor(exePath);
      if (real == null) return null;

      final file = File(real);
      if (!await file.exists()) return null;
      if (await file.length() > _maxExeBytes) return null;

      final png = pngIconFromPeBytes(await file.readAsBytes());
      if (png == null) return null;

      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final dest = p.join(cacheDir.path, 'exe-${_slug(real)}.png');
      await File(dest).writeAsBytes(png);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// Maps [exePath] to a readable local path: a real absolute path as-is, or a
  /// Windows `C:\…` path resolved into whichever CrossOver bottle actually
  /// holds it.
  String? _realPathFor(String exePath) {
    // Already a real, existing path (native game, or a bottle-absolute path).
    if (exePath.startsWith('/') && File(exePath).existsSync()) return exePath;

    // Windows path: drop the drive, split on either slash, find the bottle.
    final drive = RegExp(r'^[A-Za-z]:[\\/]').firstMatch(exePath);
    final rel = drive == null ? exePath : exePath.substring(drive.end);
    final segments = rel.split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty);
    if (segments.isEmpty) return null;
    for (final driveC in bottleDriveCs()) {
      final candidate = p.joinAll([driveC.path, ...segments]);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String _slug(String path) =>
      path.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
}

/// Every CrossOver bottle's `drive_c` directory (macOS). Empty elsewhere —
/// on native Windows/Linux the process path is already a real path, so no
/// bottle mapping is needed.
List<Directory> _defaultBottleDriveCs() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || !Platform.isMacOS) return const [];
  final bottles = Directory(
      p.join(home, 'Library', 'Application Support', 'CrossOver', 'Bottles'));
  if (!bottles.existsSync()) return const [];
  final out = <Directory>[];
  try {
    for (final b in bottles.listSync()) {
      if (b is! Directory) continue;
      final driveC = Directory(p.join(b.path, 'drive_c'));
      if (driveC.existsSync()) out.add(driveC);
    }
  } catch (_) {
    // Best-effort.
  }
  return out;
}

/// The executable path for [pid] via `ps -axo pid=,comm=` — the same
/// sanctioned process-list read `ProcessWatcherSource` uses, here keeping the
/// full path (Wine writes the Windows `C:\…\Game.exe` into comm).
Future<String?> _psExePathForPid(int pid) async {
  try {
    final res = await Process.run('ps', ['-axo', 'pid=,comm=']);
    if (res.exitCode != 0) return null;
    for (final line in const LineSplitter().convert(res.stdout.toString())) {
      final trimmed = line.trimLeft();
      final sp = trimmed.indexOf(' ');
      if (sp <= 0) continue;
      final linePid = int.tryParse(trimmed.substring(0, sp));
      if (linePid == pid) return trimmed.substring(sp + 1).trim();
    }
  } catch (_) {
    // Fall through to null.
  }
  return null;
}
