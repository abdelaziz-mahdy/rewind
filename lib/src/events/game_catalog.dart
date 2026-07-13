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

  const CatalogGame({
    required this.gameId,
    required this.displayName,
    required this.processMatch,
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
  CatalogGame(
    gameId: 'app:valorant',
    displayName: 'VALORANT',
    processMatch: 'VALORANT',
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
];
