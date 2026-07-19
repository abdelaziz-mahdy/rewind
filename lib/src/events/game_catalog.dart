import '../games/game_descriptor.dart' show gameDescriptors;

/// A well-known game Rewind can offer auto-detection for out of the box,
/// via generic OS process-list matching (see `ProcessWatcherSource`) rather
/// than a per-game vendor API integration.
///
/// [gameId] is namespaced `app:<slug>` — distinct from vendor-integrated
/// games like League of Legends (`league_of_legends`, from
/// [LeagueEventWatcher]) — so a catalog entry never collides with, and
/// never duplicates activity for, a game that already has its own
/// dedicated [GameEventSource]. See `source_builder.dart`.
class CatalogGame {
  final String gameId;
  final String displayName;

  /// Case-insensitive substring matched against running process/executable
  /// basenames (see `ProcessWatcherSource.processMatch`).
  final String processMatch;

  /// Whether this entry activating means the user is actually PLAYING, for
  /// the `captureOnlyInGame` buffer policy (see
  /// `GameEventSource.countsAsPlaying`). True for every catalog entry except
  /// the League client (see that entry's comment below) — for the rest, the
  /// detected process IS the game.
  final bool countsAsPlaying;

  const CatalogGame({
    required this.gameId,
    required this.displayName,
    required this.processMatch,
    this.countsAsPlaying = true,
  });
}

/// Popular, frequently-streamed/clipped titles with no sanctioned vendor
/// event API (see `docs/COMPLIANCE.md`) — so, unlike League of Legends,
/// they only get generic process-presence detection (buffer-length
/// selection, activity in the UI), never auto-clip-on-event. Process names
/// below are the well-known Windows executable basenames (matching is
/// case-insensitive and substring-based, so e.g. `cs2` also matches
/// `cs2.exe`); a macOS build of a given title may use a different process
/// name, in which case detection for that title simply never fires there
/// (never a crash — `ProcessWatcherSource.isGameRunning` just returns
/// false).
const List<CatalogGame> popularGamesCatalog = [
  // The current League client process (Riot ported it off Chromium Embedded
  // Framework's old "League of Legends.exe" some years back); League also
  // has a full vendor-API integration (`LeagueEventWatcher`, gameId
  // `league_of_legends`) for in-match auto-clip — this catalog entry uses a
  // *different* gameId (`app:league_of_legends`) so it only ever adds
  // generic "client is open" detection alongside that, never replaces or
  // double-activates it.
  CatalogGame(
    gameId: 'app:league_of_legends',
    displayName: 'League of Legends',
    processMatch: 'LeagueClientUx',
    // The CLIENT process, not the game: it's running through lobby/champ
    // select/post-game, not just while a match is live, so it must not
    // count as "playing" for the captureOnlyInGame buffer policy — that's
    // exactly what LeagueEventWatcher's OWN activation already means (the
    // Live Client Data API on :2999 only exists mid-match). This entry
    // stays TRUE for `activeGameIds`/the rail's "Running" dot — the client
    // being open is still worth showing — just not for the buffer policy.
    countsAsPlaying: false,
  ),
  CatalogGame(
    gameId: 'app:cs2',
    displayName: 'Counter-Strike 2',
    processMatch: 'cs2',
  ),
  CatalogGame(
    gameId: 'app:dota2',
    displayName: 'Dota 2',
    processMatch: 'dota2',
  ),
  // Windows-only, permanently: Vanguard (Riot's kernel-level anti-cheat)
  // blocks VM/CrossOver capture paths outright, so there is no macOS
  // detection story for this title the way there is for Wine-friendly
  // games. Riot's developer policy also restricts real-time VALORANT match
  // data (see developer.riotgames.com/docs/valorant) — the general Riot
  // policy disclaimer in docs/COMPLIANCE.md covers this — so, unlike
  // League, this stays process-detection-only forever, not "until a vendor
  // API lands."
  CatalogGame(
    gameId: 'app:valorant',
    displayName: 'VALORANT',
    processMatch: 'VALORANT-Win64-Shipping',
  ),
  CatalogGame(
    gameId: 'app:fortnite',
    displayName: 'Fortnite',
    processMatch: 'FortniteClient',
  ),
  CatalogGame(
    gameId: 'app:overwatch',
    displayName: 'Overwatch 2',
    processMatch: 'Overwatch',
  ),
  CatalogGame(
    gameId: 'app:rocket_league',
    displayName: 'Rocket League',
    processMatch: 'RocketLeague',
  ),
  // CAVEAT: Minecraft ships no distinct executable — vanilla/most launchers
  // spawn it as a bare JVM process (`java`/`javaw`), which is far too
  // generic to match here (it would false-positive on every other Java
  // app). `minecraft` only matches launchers that name the process after
  // the game itself (e.g. some bundled-JRE distributions) — detection for
  // a vanilla-launcher install simply won't fire. Included anyway because
  // it's one of the most-streamed/clipped titles and a partial match is
  // still useful; a real fix needs a launcher-specific integration, not a
  // process-name tweak.
  CatalogGame(
    gameId: 'app:minecraft',
    displayName: 'Minecraft',
    processMatch: 'minecraft',
  ),
  CatalogGame(
    gameId: 'app:apex_legends',
    displayName: 'Apex Legends',
    processMatch: 'r5apex',
  ),
  CatalogGame(
    gameId: 'app:pubg',
    displayName: 'PUBG: BATTLEGROUNDS',
    processMatch: 'TslGame',
  ),
  CatalogGame(
    gameId: 'app:gta5',
    displayName: 'Grand Theft Auto V',
    processMatch: 'GTA5',
  ),
  CatalogGame(
    gameId: 'app:rainbow_six_siege',
    displayName: 'Rainbow Six Siege',
    processMatch: 'RainbowSix',
  ),
  CatalogGame(
    gameId: 'app:genshin_impact',
    displayName: 'Genshin Impact',
    processMatch: 'GenshinImpact',
  ),
  // No sanctioned real-time source exists (research verdict 2026-07-19, see
  // docs/COMPLIANCE.md): no public match/event API, and Rivals' own logs are
  // encrypted — so, like VALORANT, this is process-detection only. Matches
  // the game binary itself, NOT `MarvelRivals_Launcher.exe` (the launcher
  // runs outside matches and would false-report "playing"). Works natively
  // on Windows and, unlike VALORANT, on macOS via CrossOver — NetEase ships
  // no kernel-level anti-cheat that blocks Wine the way Vanguard does.
  CatalogGame(
    gameId: 'app:marvel_rivals',
    displayName: 'Marvel Rivals',
    processMatch: 'Marvel-Win64-Shipping',
    countsAsPlaying: true,
  ),
];

/// User-created display names (from `GameConfig.displayName` — apps picked
/// via the capture-source menu, whose real casing the `app:<slug>` gameId
/// loses). Module state rather than a parameter because [displayNameFor]'s
/// call sites (clip tiles, the player, the rail) mostly have no settings
/// access; `main.dart` refreshes it at startup and on every settings change.
final Map<String, String> _customDisplayNames = {};

/// Replace the custom-name table with [names] (gameId → display name).
void registerCustomDisplayNames(Map<String, String> names) {
  _customDisplayNames
    ..clear()
    ..addAll(names);
}

/// Human-friendly label for a gameId, used everywhere a gameId is shown to
/// the user (status strip, clip rows, the filter rail, per-game settings).
/// Resolution order: a [popularGamesCatalog] hit (covers process-detected
/// `app:<slug>` ids) first, then the null/`'desktop'` sentinel, then a
/// [registerCustomDisplayNames] entry, then a registered
/// `games/game_descriptor.dart` entry (covers a vendor id with no catalog
/// counterpart, e.g. League's `league_of_legends` — a "known-name map" of
/// one before Task 21's registry), then generic title-casing on underscores.
///
/// Deliberately scans [gameDescriptors] directly rather than calling
/// `descriptorFor` (which falls back to *this* function for an unregistered
/// id's display name) — that would recurse.
String displayNameFor(String? gameId) {
  if (gameId == null || gameId == 'desktop') return 'Desktop';
  for (final game in popularGamesCatalog) {
    if (game.gameId == gameId) return game.displayName;
  }
  final custom = _customDisplayNames[gameId];
  if (custom != null) return custom;
  for (final d in gameDescriptors) {
    if (d.mergedGameIds.contains(gameId)) return d.displayName;
  }
  return titleCaseGameId(gameId);
}

/// Generic underscore-to-title-case fallback ("my_cool_game" -> "My Cool
/// Game") — the last resort in [displayNameFor], and reused by
/// `GameDescriptor.descriptorFor` for a fully unrecognized id's synthesized
/// default display name (so neither call site duplicates this logic).
String titleCaseGameId(String gameId) => gameId
    .split('_')
    .where((word) => word.isNotEmpty)
    .map((word) => word[0].toUpperCase() + word.substring(1))
    .join(' ');
