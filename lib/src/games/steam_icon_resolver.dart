import 'dart:io';

import 'package:path/path.dart' as p;

/// Real, game-specific art resolved from a local Steam install for a game
/// that has no macOS `.app` bundle to read an icon from (Steam titles run
/// through CrossOver/Wine, and native Steam games too).
///
/// Rewind ships no bundled artwork (see `GameTileAvatar`'s doc on why the
/// monogram fallback exists). This reads what Steam has ALREADY downloaded
/// to the user's own disk — the same "sanctioned local source, nothing
/// copied into the repo" stance as reading a running app's `.icns` — and
/// caches a copy next to the clips so the UI can render it.
class SteamGameArt {
  /// Steam application id (the `appmanifest_<appId>.acf` number).
  final String appId;

  /// Steam's own display name for the game (e.g. `R.E.P.O.`), which is
  /// nicer than the bare exe/window name a running Wine app reports.
  final String name;

  /// Absolute path to a cached copy of the game's icon (or capsule art when
  /// no square icon exists) inside the resolver's cache directory.
  final String iconPath;

  const SteamGameArt({
    required this.appId,
    required this.name,
    required this.iconPath,
  });
}

/// Locates a game in the local Steam library by its install directory (the
/// folder under `steamapps/common/`) or by a running Windows exe path, and
/// returns [SteamGameArt] with a cached icon. Pure `dart:io` + filesystem —
/// no native code, so it works identically on Windows, macOS (CrossOver
/// bottles) and Linux; only the default library locations differ.
///
/// Synchronous by design (like `loadAppIconPng`): resolution reads a handful
/// of small `.acf` files and copies one icon once, then memoizes — so the
/// UI seam can hand a path straight to an `Image`. Never throws; every miss
/// (no library, no manifest, no art) resolves to `null`.
class SteamIconResolver {
  /// Where resolved icons are cached (one file per appid). Created on first
  /// write.
  final Directory cacheDir;

  /// Returns the `steamapps` directories to search. Injectable for tests;
  /// defaults to the OS's known Steam locations plus CrossOver bottles.
  final List<Directory> Function() steamappsRoots;

  SteamIconResolver({
    required this.cacheDir,
    List<Directory> Function()? steamappsRoots,
  }) : steamappsRoots = steamappsRoots ?? defaultSteamappsRoots;

  Map<String, _Manifest>? _index;
  final Map<String, SteamGameArt?> _artByInstallDir = {};

  /// Resolves art for the game installed in [installDir] (case- and
  /// punctuation-insensitive: a running window owner "half life 2" matches
  /// the `Half-Life 2` install folder). Null when no matching game or no
  /// cached art is found.
  SteamGameArt? resolveByInstallDir(String installDir) {
    final key = _norm(installDir);
    if (key.isEmpty) return null;
    if (_artByInstallDir.containsKey(key)) return _artByInstallDir[key];
    final art = _resolve(key);
    _artByInstallDir[key] = art;
    return art;
  }

  /// Resolves art from a running game's exe path (native or the Windows
  /// `C:\…\steamapps\common\<dir>\<exe>.exe` a Wine process reports),
  /// extracting the install dir from the `steamapps/common/<dir>` segment.
  SteamGameArt? resolveByExePath(String exePath) {
    final dir = _installDirFromPath(exePath);
    return dir == null ? null : resolveByInstallDir(dir);
  }

  /// The Steam appid + name for [installDir] if it's an INSTALLED Steam game
  /// (there's an `appmanifest` for it under `steamapps/common`), regardless
  /// of whether any art has been cached. This is the authoritative "this
  /// running app IS a game" signal — a running window owner like
  /// `explorer.exe` or `steamwebhelper.exe` has no manifest and returns
  /// null, so suggestions can trust it where the "bundle-less = probably a
  /// game" heuristic guesses. Use [resolveByInstallDir] when you also want
  /// the icon.
  ({String appId, String name})? steamGameByInstallDir(String installDir) {
    final key = _norm(installDir);
    if (key.isEmpty) return null;
    final index = _index ??= _buildIndex();
    final m = index[key];
    return m == null ? null : (appId: m.appId, name: m.name);
  }

  SteamGameArt? _resolve(String normalizedInstallDir) {
    final index = _index ??= _buildIndex();
    final manifest = index[normalizedInstallDir];
    if (manifest == null) return null;
    final iconSource = _findArtFile(manifest.steamRoot, manifest.appId);
    if (iconSource == null) return null;
    final cached = _cacheIcon(manifest.appId, iconSource);
    if (cached == null) return null;
    return SteamGameArt(
        appId: manifest.appId, name: manifest.name, iconPath: cached);
  }

  /// Scans every steamapps root (following one level of extra libraries via
  /// `libraryfolders.vdf`) and maps normalized install dir -> manifest.
  Map<String, _Manifest> _buildIndex() {
    final index = <String, _Manifest>{};
    final seen = <String>{};
    final work = <Directory>[...steamappsRoots()];
    while (work.isNotEmpty) {
      final steamapps = work.removeLast();
      String canon;
      try {
        if (!steamapps.existsSync()) continue;
        canon = p.canonicalize(steamapps.path);
      } catch (_) {
        continue;
      }
      if (!seen.add(canon)) continue;

      // Extra libraries declared in this root's libraryfolders.vdf.
      for (final extra in _libraryFolders(steamapps)) {
        work.add(extra);
      }

      try {
        for (final entity in steamapps.listSync()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!name.startsWith('appmanifest_') ||
              !name.endsWith('.acf')) {
            continue;
          }
          final m = _parseManifest(entity, steamapps.parent);
          if (m != null) index.putIfAbsent(_norm(m.installDir), () => m);
        }
      } catch (_) {
        // Unreadable library — skip, best-effort.
      }
    }
    return index;
  }

  List<Directory> _libraryFolders(Directory steamapps) {
    final vdf = File(p.join(steamapps.path, 'libraryfolders.vdf'));
    if (!vdf.existsSync()) return const [];
    String text;
    try {
      text = vdf.readAsStringSync();
    } catch (_) {
      return const [];
    }
    final out = <Directory>[];
    for (final match
        in RegExp(r'"path"\s*"([^"]+)"').allMatches(text)) {
      final raw = match.group(1)!.replaceAll(r'\\', r'\');
      out.add(Directory(p.join(raw, 'steamapps')));
    }
    return out;
  }

  _Manifest? _parseManifest(File acf, Directory steamRoot) {
    String text;
    try {
      text = acf.readAsStringSync();
    } catch (_) {
      return null;
    }
    final appId = _value(text, 'appid');
    final installDir = _value(text, 'installdir');
    if (appId == null || installDir == null) return null;
    final name = _value(text, 'name') ?? installDir;
    return _Manifest(
      appId: appId,
      name: name,
      installDir: installDir,
      steamRoot: steamRoot,
    );
  }

  /// The best art file for [appId] under `appcache/librarycache/<appId>/`:
  /// the loose square icon directly in that dir (smallest, the community
  /// icon), else a `library_600x900.jpg` capsule in a subfolder, else a
  /// `logo.png`. Null when the game has no cached art.
  File? _findArtFile(Directory steamRoot, String appId) {
    final dir = Directory(
        p.join(steamRoot.path, 'appcache', 'librarycache', appId));
    if (!dir.existsSync()) return null;

    File? smallestLoose;
    File? capsule;
    File? logo;
    try {
      for (final e in dir.listSync(recursive: true)) {
        if (e is! File) continue;
        final base = p.basename(e.path).toLowerCase();
        final ext = p.extension(base);
        final isImage =
            ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.ico';
        if (!isImage) continue;
        final loose = p.equals(p.dirname(e.path), dir.path);
        if (loose) {
          if (smallestLoose == null ||
              e.lengthSync() < smallestLoose.lengthSync()) {
            smallestLoose = e;
          }
        } else if (base == 'library_600x900.jpg') {
          capsule = e;
        } else if (base == 'logo.png') {
          logo = e;
        }
      }
    } catch (_) {
      return null;
    }
    return smallestLoose ?? capsule ?? logo;
  }

  String? _cacheIcon(String appId, File source) {
    try {
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final ext = p.extension(source.path).toLowerCase();
      final dest = p.join(cacheDir.path, 'steam-$appId$ext');
      final destFile = File(dest);
      if (!destFile.existsSync()) source.copySync(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }
}

class _Manifest {
  final String appId;
  final String name;
  final String installDir;

  /// The Steam root (parent of `steamapps`) this manifest lives under —
  /// where `appcache/librarycache/<appId>` for its art is found.
  final Directory steamRoot;

  const _Manifest({
    required this.appId,
    required this.name,
    required this.installDir,
    required this.steamRoot,
  });
}

/// Lowercases and strips every non-alphanumeric character, so install-dir
/// comparisons ignore hyphens, dots, spaces and case (`R.E.P.O.` ~ `repo`,
/// `Half-Life 2` ~ `half life 2`).
String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Reads a `"key" "value"` pair from an ACF/VDF blob (whitespace-tolerant,
/// first match wins). Null when the key is absent.
String? _value(String text, String key) {
  final m = RegExp('"$key"\\s*"([^"]*)"', caseSensitive: false).firstMatch(text);
  return m?.group(1);
}

/// Extracts the install dir from a `steamapps/common/<dir>/…` path (either
/// slash style), or null if the path isn't inside a Steam common folder.
String? _installDirFromPath(String path) {
  final m = RegExp(r'steamapps[\\/]+common[\\/]+([^\\/]+)',
          caseSensitive: false)
      .firstMatch(path);
  return m?.group(1);
}

/// The OS's likely `steamapps` directories: native Steam plus, on macOS,
/// every CrossOver bottle's bundled Steam. Only existing dirs are returned.
List<Directory> defaultSteamappsRoots() {
  final home = _home();
  final candidates = <String>[];
  if (Platform.isMacOS) {
    if (home != null) {
      candidates
          .add(p.join(home, 'Library', 'Application Support', 'Steam', 'steamapps'));
      candidates.addAll(_crossOverSteamapps(home));
    }
  } else if (Platform.isWindows) {
    candidates.add(r'C:\Program Files (x86)\Steam\steamapps');
    candidates.add(r'C:\Program Files\Steam\steamapps');
  } else {
    if (home != null) {
      candidates.add(p.join(home, '.steam', 'steam', 'steamapps'));
      candidates.add(p.join(home, '.local', 'share', 'Steam', 'steamapps'));
      candidates.add(p.join(home, '.var', 'app', 'com.valvesoftware.Steam',
          'data', 'Steam', 'steamapps'));
    }
  }
  return [
    for (final c in candidates)
      if (Directory(c).existsSync()) Directory(c),
  ];
}

/// Every `.../drive_c/**/Steam/steamapps` across all CrossOver bottles.
List<String> _crossOverSteamapps(String home) {
  final bottles = Directory(
      p.join(home, 'Library', 'Application Support', 'CrossOver', 'Bottles'));
  if (!bottles.existsSync()) return const [];
  final out = <String>[];
  try {
    for (final bottle in bottles.listSync()) {
      if (bottle is! Directory) continue;
      final driveC = p.join(bottle.path, 'drive_c');
      for (final steam in const [
        ['Program Files (x86)', 'Steam', 'steamapps'],
        ['Program Files', 'Steam', 'steamapps'],
      ]) {
        out.add(p.joinAll([driveC, ...steam]));
      }
    }
  } catch (_) {
    // Best-effort enumeration.
  }
  return out;
}

String? _home() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
