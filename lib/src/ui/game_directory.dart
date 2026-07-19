import '../clip/clip.dart';
import '../events/game_catalog.dart';
import '../games/game_descriptor.dart';
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

const _desktopId = 'desktop';

/// Descriptors whose row must merge more than one gameId into one — League
/// (the vendor id + [popularGamesCatalog]'s `app:league_of_legends` entry)
/// is the only one today, but this is driven by the registry, not a
/// hardcoded League check (Task 21) — a future game with the same "vendor
/// integration + generic catalog entry" shape merges automatically.
Iterable<GameDescriptor> get _mergedDescriptors =>
    gameDescriptors.where((d) => d.mergedGameIds.length > 1);

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
  final mergedDescriptors = _mergedDescriptors.toList();

  final candidateIds = <String>{
    ...configById.keys,
    for (final c in clips) c.gameId,
    ...activeIds,
  }..remove(_desktopId);
  for (final d in mergedDescriptors) {
    candidateIds.removeAll(d.mergedGameIds);
  }

  final entries = <GameEntry>[
    for (final d in mergedDescriptors)
      if (_descriptorIsPresent(d, clips, activeIds, configById))
        _buildMergedEntry(d, catalogById, configById, clips, activeIds),
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

/// Task 28's rename precedence, resolved straight from [configById] rather
/// than through `displayNameFor`'s `registerCustomDisplayNames` side-channel
/// (which `main.dart` only refreshes asynchronously, in its `onChanged`
/// callback) — so a just-committed rename is reflected the instant
/// [buildGameDirectory] is next called (e.g. when Settings closes), and this
/// stays unit-testable without a `registerCustomDisplayNames` call first.
/// Same precedence either way: a non-empty [GameConfig.displayName]
/// override, when [isGameRenameable], beats the catalog/descriptor/
/// title-case fallback [displayNameFor] itself falls through to.
String _resolveDisplayName(String gameId, Map<String, GameConfig> configById) {
  final override = configById[gameId]?.displayName;
  if (override != null &&
      override.trim().isNotEmpty &&
      isGameRenameable(gameId)) {
    return override;
  }
  return displayNameFor(gameId);
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

/// Whether any of [d]'s merged ids has a config row, a clip, or live
/// activity — the generic form of the old `hasLeague` gate: a merged row
/// only appears once one of its halves has actually been seen (§3.5).
bool _descriptorIsPresent(
  GameDescriptor d,
  List<Clip> clips,
  Set<String> activeIds,
  Map<String, GameConfig> configById,
) =>
    d.mergedGameIds.any((id) =>
        configById.containsKey(id) ||
        activeIds.contains(id) ||
        clips.any((c) => c.gameId == id));

/// Builds the one directory row for a descriptor with more than one merged
/// gameId (League): keyed at [GameDescriptor.primaryGameId], covering clips/
/// activity under ANY of its [GameDescriptor.mergedGameIds], with the
/// [DetectionMethod] union of every id's own detection plus
/// [DetectionMethod.liveClientApi] when [GameDescriptor.hasLiveFeed].
GameEntry _buildMergedEntry(
  GameDescriptor d,
  Map<String, CatalogGame> catalogById,
  Map<String, GameConfig> configById,
  List<Clip> clips,
  Set<String> activeIds,
) {
  final detection = <DetectionMethod>{
    if (d.hasLiveFeed) DetectionMethod.liveClientApi,
    for (final id in d.mergedGameIds)
      ..._detectionFor(id, catalogById, configById),
  };
  String? processMatch;
  for (final id in d.mergedGameIds) {
    final match = catalogById[id]?.processMatch ?? configById[id]?.processMatch;
    if (match != null) {
      processMatch = match;
      break;
    }
  }
  return _buildEntry(
    gameId: d.primaryGameId,
    matchIds: d.mergedGameIds,
    detection: detection,
    processMatch: processMatch,
    clips: clips,
    activeIds: activeIds,
    configById: configById,
  );
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
    displayName: _resolveDisplayName(gameId, configById),
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
