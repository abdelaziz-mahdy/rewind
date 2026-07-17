import '../clip/clip.dart';
import '../events/game_catalog.dart';
import '../settings/app_settings.dart';
import '../settings/game_config.dart';
import 'capture_app_match.dart' show usesOfficialLogo;

/// How Rewind knows a game is running, shown to the user so they understand
/// what auto-clipping (if any) to expect — see `docs/COMPLIANCE.md`.
enum DetectionMethod {
  /// A sanctioned vendor API (e.g. League's Live Client Data endpoint) —
  /// the only method that can drive auto-clip-on-event.
  liveClientApi,

  /// Generic OS process-name matching (`ProcessWatcherSource`) — presence
  /// only, no events, so buffer-length selection but never auto-clip.
  processWatch,

  /// No detection at all: clips only ever come from the manual hotkey
  /// (the `desktop` pseudo-game).
  manual,
}

/// One row in the game directory (the left rail, and the source list for
/// the Supported Games screen): a game the user has configured, has clips
/// for, or is currently seen running — with everything the UI needs to
/// render it, derived from existing data only (no invented stats).
class GameEntry {
  final String gameId;
  final String displayName;
  final Set<DetectionMethod> detection;

  /// The process substring Rewind matches to detect this game, when
  /// [detection] includes [DetectionMethod.processWatch]. Null otherwise.
  final String? processMatch;
  final bool active;

  /// True only when the entry's OWN gameId (the vendor-API id, for a merged
  /// row like League) is what's active. The merged League row is [active]
  /// whenever EITHER half fires, but "client open in the lobby"
  /// (`app:league_of_legends`, process watch) and "in a match"
  /// (`league_of_legends`, Live Client API) are very different claims —
  /// the hub's status line must not say "In match" for a lobby.
  final bool vendorActive;
  final int clipCount;
  final int totalSizeBytes;
  final DateTime? lastClipAt;

  /// The real app icon for this game, when one has ever been captured (see
  /// [GameConfig.iconPath]'s doc for how/when). Null falls back to the
  /// FNV-monogram tile — the deliberate look for Wine games and any game
  /// never matched to a running app.
  final String? iconPath;

  const GameEntry({
    required this.gameId,
    required this.displayName,
    required this.detection,
    this.processMatch,
    required this.active,
    this.vendorActive = false,
    required this.clipCount,
    required this.totalSizeBytes,
    this.lastClipAt,
    this.iconPath,
  });
}

/// League of Legends has two gameIds in play: the vendor integration
/// (`LeagueEventWatcher.gameId`) that drives auto-clip-on-event, and the
/// generic [popularGamesCatalog] process-detection entry that merely notices
/// the client is open (see `source_builder.dart`). Shown separately they'd
/// read as two different games; §3.5 of the redesign spec merges them into
/// a single row carrying both [DetectionMethod]s.
const _leagueVendorId = 'league_of_legends';
const _leagueCatalogId = 'app:league_of_legends';

const _desktopId = 'desktop';

/// Builds the game directory: the union of every game with a [GameConfig]
/// row, clips in the library, or live activity, plus the pinned `desktop`
/// pseudo-game — merged, sorted, and stats-annotated per the redesign
/// spec's IA (§1) and Supported Games merge rule (§3.5). Pure function of
/// its inputs: no listening, no side effects.
List<GameEntry> buildGameDirectory({
  required AppSettings settings,
  required List<Clip> clips,
  required Set<String> activeIds,
}) {
  final catalogById = {for (final g in popularGamesCatalog) g.gameId: g};
  final configById = {for (final c in settings.allConfigs) c.gameId: c};

  final candidateIds = <String>{
    ...configById.keys,
    for (final c in clips) c.gameId,
    ...activeIds,
  }
    ..remove(_leagueVendorId)
    ..remove(_leagueCatalogId)
    ..remove(_desktopId);

  final hasLeague = configById.containsKey(_leagueVendorId) ||
      configById.containsKey(_leagueCatalogId) ||
      activeIds.contains(_leagueVendorId) ||
      activeIds.contains(_leagueCatalogId) ||
      clips.any(
          (c) => c.gameId == _leagueVendorId || c.gameId == _leagueCatalogId);

  final entries = <GameEntry>[
    if (hasLeague)
      _buildEntry(
        gameId: _leagueVendorId,
        matchIds: const {_leagueVendorId, _leagueCatalogId},
        detection: const {
          DetectionMethod.liveClientApi,
          DetectionMethod.processWatch,
        },
        processMatch: catalogById[_leagueCatalogId]?.processMatch,
        clips: clips,
        activeIds: activeIds,
        configById: configById,
      ),
    for (final gameId in candidateIds)
      _buildEntry(
        gameId: gameId,
        matchIds: {gameId},
        detection: _detectionFor(gameId, catalogById, configById),
        processMatch: catalogById[gameId]?.processMatch ??
            configById[gameId]?.processMatch,
        clips: clips,
        activeIds: activeIds,
        configById: configById,
      ),
  ];

  // Active games first, then alphabetical by display name — desktop is
  // excluded from this sort and pinned last below regardless of activity
  // (it is never reported active by the registry, but pin it unconditionally
  // so it always reads as the manual-clips home rather than sorting in).
  entries.sort((a, b) {
    if (a.active != b.active) return a.active ? -1 : 1;
    return a.displayName.compareTo(b.displayName);
  });

  final desktop = _buildEntry(
    gameId: _desktopId,
    matchIds: const {_desktopId},
    detection: const {DetectionMethod.manual},
    processMatch: null,
    clips: clips,
    activeIds: activeIds,
    configById: configById,
  );

  return [...entries, desktop];
}

Set<DetectionMethod> _detectionFor(
  String gameId,
  Map<String, CatalogGame> catalogById,
  Map<String, GameConfig> configById,
) {
  if (catalogById.containsKey(gameId)) return {DetectionMethod.processWatch};
  if (configById[gameId]?.processMatch != null) {
    return {DetectionMethod.processWatch};
  }
  return const {};
}

GameEntry _buildEntry({
  required String gameId,
  required Set<String> matchIds,
  required Set<DetectionMethod> detection,
  required String? processMatch,
  required List<Clip> clips,
  required Set<String> activeIds,
  required Map<String, GameConfig> configById,
}) {
  final matchingClips = clips.where((c) => matchIds.contains(c.gameId));
  var clipCount = 0;
  var totalSizeBytes = 0;
  DateTime? lastClipAt;
  for (final c in matchingClips) {
    clipCount++;
    totalSizeBytes += c.sizeBytes;
    if (lastClipAt == null || c.createdAt.isAfter(lastClipAt)) {
      lastClipAt = c.createdAt;
    }
  }
  // A merged row (League) can have the icon captured under either of its
  // matchIds — whichever was actually matched to a running app first.
  //
  // Defensively re-checked here (not just at capture time — see
  // `ClipCoordinator._autoSwitchCaptureFor`/`_SourceLine._pickApp`) so an
  // `iconPath` persisted by a pre-fix version of Rewind never renders:
  // League's app icon is Riot's official logo, which Riot's policy forbids
  // using (see `usesOfficialLogo`'s doc) — champion/item art (DDragon) is
  // unaffected, this is ONLY about the OS-extracted app icon.
  String? iconPath;
  if (!usesOfficialLogo(gameId: gameId)) {
    for (final id in matchIds) {
      if (configById[id]?.iconPath case final path?) {
        iconPath = path;
        break;
      }
    }
  }
  return GameEntry(
    gameId: gameId,
    displayName: displayNameFor(gameId),
    detection: detection,
    processMatch: processMatch,
    active: matchIds.any(activeIds.contains),
    vendorActive: activeIds.contains(gameId),
    clipCount: clipCount,
    totalSizeBytes: totalSizeBytes,
    lastClipAt: lastClipAt,
    iconPath: iconPath,
  );
}
