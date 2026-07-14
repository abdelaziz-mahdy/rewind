import '../events/game_catalog.dart';
import '../obs/app_info.dart';

/// True if [processMatch] is a case-insensitive substring of [app]'s name or
/// bundle id — the exact matching `ClipCoordinator._autoSwitchCaptureFor`
/// uses to decide whether a currently-capturable app "is" a given game. UI
/// code that needs the same answer (the one-click record banner's Record
/// button, the capture-source chip's "remember this app" write) uses this
/// instead of re-deriving it, so both stay consistent with the coordinator's
/// own auto-switch behavior without reaching into it (the coordinator is
/// off-limits for this round of UI work).
bool appMatchesProcess(AppInfo app, String processMatch) {
  final needle = processMatch.toLowerCase();
  return app.name.toLowerCase().contains(needle) ||
      app.bundleId.toLowerCase().contains(needle);
}

/// The first currently-capturable app matching [processMatch], or null if
/// none is running (yet).
AppInfo? findRunningApp(String processMatch, List<AppInfo> apps) {
  for (final app in apps) {
    if (appMatchesProcess(app, processMatch)) return app;
  }
  return null;
}

/// The [popularGamesCatalog] entry (if any) whose `processMatch` matches
/// [app] — so picking an app that's already a catalog game (e.g. picking
/// "Counter-Strike 2" from the capture-source menu) reuses that entry's
/// gameId instead of minting a second, duplicate row for the same game.
CatalogGame? matchingCatalogGame(AppInfo app,
    [List<CatalogGame> catalog = popularGamesCatalog]) {
  for (final g in catalog) {
    if (appMatchesProcess(app, g.processMatch)) return g;
  }
  return null;
}

/// Lowercases [input] and collapses every run of characters outside
/// `[a-z0-9]` into a single underscore, trimming leading/trailing
/// underscores — the same slug shape as the catalog's own `app:<slug>`
/// gameIds (see `game_catalog.dart`), so a picked app's generated id reads
/// like it belongs next to them.
String slugify(String input) {
  final lower = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  return lower.replaceAll(RegExp(r'^_+|_+$'), '');
}

/// The gameId a picked capture-source [app] should be remembered under: an
/// existing catalog entry's gameId when [app] matches one (no duplicate row
/// for a game the catalog already knows), else a fresh `app:<slug>` derived
/// from the app's display name — falling back to its bundle id if the name
/// slugifies to nothing (e.g. a name made entirely of symbols/emoji).
String gameIdForApp(AppInfo app,
    [List<CatalogGame> catalog = popularGamesCatalog]) {
  final catalogMatch = matchingCatalogGame(app, catalog);
  if (catalogMatch != null) return catalogMatch.gameId;
  final nameSlug = slugify(app.name);
  final slug = nameSlug.isNotEmpty ? nameSlug : slugify(app.bundleId);
  return 'app:$slug';
}
