import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/log.dart';
import '../settings/app_settings.dart';

/// Copies every game icon Rewind merely POINTS at into its own cache, so the
/// rail keeps its icons when the original goes away.
///
/// Icons arrive from four places and only two of them were already local: the
/// Steam library lookup and the exe reader both write a copy into the cache
/// dir. The other two — a macOS app bundle's `.icns`, and a picture the user
/// picked themselves — were stored as a path into wherever they happened to
/// live. For a game installed on an external drive that is a path that stops
/// existing the moment the drive is unplugged, and the game silently drops
/// back to a letter monogram:
///
///     /Volumes/gaming/SteamLibrary/steamapps/common/Big Walk/Big Walk.app/
///         Contents/Resources/PlayerIcon.icns
///
/// A copy is small (an `.icns` is tens of KB) and makes the icon independent
/// of the drive, of the game being moved, and of it being uninstalled.
///
/// Best-effort and idempotent: an icon already inside [cacheDir] is left
/// alone, an unreachable source is left for a later run (the drive may come
/// back), and any failure leaves the existing path untouched rather than
/// clearing it. Mutates [settings] in place and returns how many games were
/// rewritten — 0 means there is nothing to persist.
Future<int> localizeGameIcons(AppSettings settings, Directory cacheDir) async {
  var changed = 0;
  // Snapshot: setConfig writes back into the map allConfigs iterates.
  for (final cfg in settings.allConfigs.toList()) {
    final source = cfg.iconPath;
    if (source == null || source.isEmpty) continue;
    if (p.isWithin(cacheDir.path, source)) continue; // already ours

    final file = File(source);
    if (!file.existsSync()) continue; // drive unplugged, or game removed

    try {
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      // Named after the GAME, not the source path: the same game reinstalled
      // somewhere else should overwrite its own icon rather than accumulate
      // a second copy.
      final dest = p.join(
        cacheDir.path,
        'game-${_slug(cfg.gameId)}${p.extension(source)}',
      );
      file.copySync(dest);
      cfg.iconPath = dest;
      settings.setConfig(cfg);
      changed++;
    } on FileSystemException catch (err) {
      // A copy that fails leaves the original path in place — a working
      // reference beats a broken one.
      talker.debug('Could not copy ${cfg.gameId}\'s icon locally: $err');
    }
  }
  return changed;
}

String _slug(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
