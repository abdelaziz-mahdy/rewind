import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/log.dart';
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

  /// Returns every CrossOver BOTTLE directory a Windows path can be resolved
  /// inside. Injectable for tests; defaults to every installed bottle.
  ///
  /// Bottle roots rather than their `drive_c`: a bottle maps each drive
  /// letter through a `dosdevices/<letter>:` symlink, and only `c:` points at
  /// drive_c. `z:` is the macOS filesystem root and is how Wine reports any
  /// game outside the bottle — e.g. one installed on an external volume,
  /// which arrives as `Z:\Volumes\gaming\...`. Resolving everything against
  /// drive_c meant every such game silently failed to produce an icon.
  final List<Directory> Function() bottleDirs;

  /// Resolves a pid to its executable path (a Windows `C:\…\Game.exe` for a
  /// Wine process, or a real path). Injectable; defaults to `ps`.
  final Future<String?> Function(int pid) exePathForPid;

  /// Skip executables larger than this — the icon isn't worth reading a
  /// pathologically huge file into memory. Real game exes sit well under it.
  static const _maxExeBytes = 300 * 1024 * 1024;

  ExeIconResolver({
    required this.cacheDir,
    List<Directory> Function()? bottleDirs,
    Future<String?> Function(int pid)? exePathForPid,
  })  : bottleDirs = bottleDirs ?? _defaultBottleDirs,
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
      if (exePath == null || exePath.isEmpty) {
        talker.debug('No icon for ${app.name}: its executable path could not '
            'be read from the process list.');
        return null;
      }
      final real = _realPathFor(exePath);
      if (real == null) {
        talker.debug('No icon for ${app.name}: "$exePath" does not map into '
            'any CrossOver bottle (drive letter not mapped, or the volume is '
            'not mounted).');
        return null;
      }

      final file = File(real);
      if (!await file.exists()) return null;
      if (await file.length() > _maxExeBytes) {
        talker.debug('No icon for ${app.name}: its executable is larger than '
            'the read limit.');
        return null;
      }

      final png = pngIconFromPeBytes(await file.readAsBytes());
      if (png == null) {
        talker.debug('No icon for ${app.name}: no readable icon resource in '
            '$real.');
        return null;
      }

      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final dest = p.join(cacheDir.path, 'exe-${_slug(real)}.png');
      await File(dest).writeAsBytes(png);
      return dest;
    } on Object catch (err) {
      // A game on an external volume is the case that actually hits this:
      // macOS refuses the READ ("Operation not permitted") unless the app has
      // been granted access to removable volumes, even though the path
      // resolves and the file is plainly there.
      talker.debug('No icon for ${app.name}: $err');
      return null;
    }
  }

  /// Maps [exePath] to a readable local path: a real absolute path as-is, or a
  /// Windows `C:\…` path resolved into whichever CrossOver bottle actually
  /// holds it.
  String? _realPathFor(String exePath) {
    // Already a real, existing path (native game, or a bottle-absolute path).
    if (exePath.startsWith('/') && File(exePath).existsSync()) return exePath;

    // Windows path: split off the drive letter, then the rest on either slash.
    final drive = RegExp(r'^([A-Za-z]):[\\/]').firstMatch(exePath);
    final rel = drive == null ? exePath : exePath.substring(drive.end);
    final letter = drive?.group(1)?.toLowerCase();
    final segments =
        rel.split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;

    for (final bottle in bottleDirs()) {
      // The bottle's own drive map is the authority: dosdevices/<letter>: is
      // a symlink to wherever that drive really lives. Guessing drive_c only
      // ever worked for C:.
      if (letter != null) {
        final link = Link(p.join(bottle.path, 'dosdevices', '$letter:'));
        if (link.existsSync()) {
          try {
            final target = link.resolveSymbolicLinksSync();
            final candidate = p.joinAll([target, ...segments]);
            if (File(candidate).existsSync()) return candidate;
          } on FileSystemException {
            // A dangling drive mapping (an unplugged volume) is not fatal —
            // another bottle may still hold this game.
          }
        }
      }
      // Fallback for a bottle with no dosdevices entry: the old drive_c join.
      final candidate = p.joinAll([bottle.path, 'drive_c', ...segments]);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String _slug(String path) =>
      path.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
}

/// Every installed CrossOver bottle (macOS). Empty elsewhere — on native
/// Windows/Linux the process path is already a real path, so no bottle
/// mapping is needed.
List<Directory> _defaultBottleDirs() {
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
      // A bottle is anything with a drive_c; its drive MAP lives next door in
      // dosdevices (see _realPathFor).
      if (Directory(p.join(b.path, 'drive_c')).existsSync()) out.add(b);
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
