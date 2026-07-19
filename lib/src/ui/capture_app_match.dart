import '../events/game_catalog.dart';
import '../games/game_descriptor.dart';
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

/// Whether a game's real, OS-extracted app icon (see `GameConfig.iconPath`'s
/// doc, captured via `_SourceLine._pickApp` / `ClipCoordinator.
/// _autoSwitchCaptureFor`) must NEVER be shown for it, because that icon IS
/// the vendor's official logo — reading it off a running app bundle at
/// runtime doesn't change what it depicts.
///
/// Riot's Developer Policies are explicit and asymmetric here: "Please
/// Don't: Use any of our official logos" vs. "Please Do: Feel free to use
/// any of our art assets from the game (but NOT any official Logos)". The
/// League client's application icon is Riot's logo, not "game art" — unlike
/// champion/item art from Data Dragon (`DDragon`), which the policy
/// explicitly permits and this predicate has NO effect on. Keep this an
/// explicit, documented exclusion — do not remove it to "fix" a missing
/// rail icon for League.
///
/// [gameId] is checked against the registered [GameDescriptor]'s
/// `usesOfficialLogo` flag first (Task 21) — covers League's two known ids
/// (the vendor integration and the catalog's process-watch entry — see
/// `game_directory.dart`'s doc on why League has both) and Marvel Rivals.
/// [bundleId] is checked as a best-effort (loose substring, not exact)
/// fallback for other Riot titles a user might pick via the generic
/// capture-source menu that have no registered descriptor, since this
/// codebase has no verified, hardcoded Riot bundle id to match exactly.
///
/// NOTE the polarity: `GameDescriptor.usesOfficialLogo` reads the opposite
/// way (`true` = safe to show the real icon, `false` = forbidden) — see its
/// doc comment. This function keeps its own original meaning (`true` =
/// showing the icon WOULD use a forbidden logo) for its existing callers.
bool usesOfficialLogo({required String gameId, String? bundleId}) {
  if (!descriptorFor(gameId).usesOfficialLogo) return true;
  final bundle = bundleId?.toLowerCase();
  return bundle != null && bundle.contains('riotgames');
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

/// Splits the capture-source menu's app list into probable games and
/// everything else, each alphabetized case-insensitively. "Game" means a
/// [popularGamesCatalog] process match, or a Windows exe under
/// CrossOver/Wine (empty bundle id — overwhelmingly games in practice, and
/// exactly the entries a user opens this menu hunting for).
({List<AppInfo> games, List<AppInfo> others}) partitionCapturableApps(
  List<AppInfo> apps, [
  List<CatalogGame> catalog = popularGamesCatalog,
]) {
  int byName(AppInfo a, AppInfo b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  final games = <AppInfo>[];
  final others = <AppInfo>[];
  for (final app in apps) {
    final isGame =
        app.bundleId.isEmpty || matchingCatalogGame(app, catalog) != null;
    (isGame ? games : others).add(app);
  }
  games.sort(byName);
  others.sort(byName);
  return (games: games, others: others);
}
