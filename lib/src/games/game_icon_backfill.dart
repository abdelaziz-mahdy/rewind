import '../obs/app_info.dart';
import '../settings/app_settings.dart';
import '../ui/capture_app_match.dart' show gameIdForApp;
import 'exe_icon_resolver.dart';
import 'steam_icon_resolver.dart';

/// Fills in a real icon for a configured game that hasn't got one, using the
/// app while it is RUNNING.
///
/// Icon resolution used to happen at exactly one place — Supported Games'
/// "Running now" Add button — while the other two ways to learn a game (the
/// detected-game banner, and picking it as a capture source) wrote a config
/// with no icon at all. A game learned either of those ways sat on a letter
/// monogram forever, because the two things that can produce an icon need the
/// game to be running: its pid, to find the exe to read the icon out of, and
/// its install directory, to match against the Steam library. Adding a manual
/// picker would have papered over that; this fixes it.
///
/// Runs against whatever is running right now, so it is worth calling
/// whenever the running-app list changes. Everything about it is
/// best-effort and idempotent: a game that already has an icon is skipped, a
/// resolution that fails leaves the monogram, and both resolvers memoize, so
/// repeat calls cost nothing.
///
/// A USER-CHOSEN icon is never touched — see [GameConfig.iconIsUserChosen].
/// Auto-resolution is what a user overrides when the resolved icon is wrong,
/// so quietly resolving over their pick would undo the fix they came for.
///
/// Mutates [settings] in place and returns the number of games updated; 0
/// means there is nothing to persist.
Future<int> backfillRunningGameIcons(
  AppSettings settings,
  List<AppInfo> runningApps, {
  SteamIconResolver? steamResolver,
  ExeIconResolver? exeResolver,
}) async {
  var changed = 0;
  // Snapshot: setConfig writes back into the map allConfigs iterates.
  final needing = [
    for (final cfg in settings.allConfigs.toList())
      if (cfg.iconPath == null || cfg.iconPath!.isEmpty) cfg,
  ];
  if (needing.isEmpty) return 0;

  for (final cfg in needing) {
    // The running app this config was learned from, matched the same way the
    // config's id was minted (gameIdForApp) rather than by name — a Wine
    // game's window title and its process name are not always the same
    // string.
    final app =
        runningApps.where((a) => gameIdForApp(a) == cfg.gameId).firstOrNull;
    if (app == null) continue;

    // Steam art first: it is the game's real store artwork, and it costs a
    // lookup in an already-parsed local library. The exe icon is the
    // fallback — correct, but it is whatever the developer embedded.
    final art = steamResolver?.resolveByInstallDir(app.name);
    final icon = art?.iconPath ?? await exeResolver?.iconForApp(app);
    if (icon == null || icon.isEmpty) continue;

    cfg.iconPath = icon;
    // A Steam lookup also knows the real name, which beats the raw exe name
    // these games are otherwise stuck with ("PenguinHotel-Win64-Shipping").
    if (art != null && (cfg.displayName == null || cfg.displayName!.isEmpty)) {
      cfg.displayName = art.name;
    }
    settings.setConfig(cfg);
    changed++;
  }
  return changed;
}
