import '../settings/app_settings.dart';
import 'steam_icon_resolver.dart';

/// Fills in a real Steam icon (and proper name) for games that were added
/// BEFORE Steam-icon resolution existed — their [GameConfig.iconPath] is
/// still null, so the rail shows a letter monogram even though Steam has the
/// art on disk. Runs once at startup.
///
/// Best-effort: only a game whose stored name or process needle maps to an
/// installed Steam game (via [SteamIconResolver]) gets one; everything else
/// is left on the monogram, unchanged. Mutates [settings] in place and
/// returns the number of games updated — 0 means there is nothing to persist.
int backfillSteamIcons(AppSettings settings, SteamIconResolver resolver) {
  var changed = 0;
  // Snapshot: setConfig writes back into the map allConfigs iterates.
  for (final cfg in settings.allConfigs.toList()) {
    if (cfg.iconPath != null && cfg.iconPath!.isNotEmpty) continue;
    for (final name in <String?>[cfg.displayName, cfg.processMatch]) {
      if (name == null || name.isEmpty) continue;
      final art = resolver.resolveByInstallDir(name);
      if (art == null) continue;
      cfg.iconPath ??= art.iconPath;
      cfg.displayName ??= art.name;
      settings.setConfig(cfg);
      changed++;
      break;
    }
  }
  return changed;
}
