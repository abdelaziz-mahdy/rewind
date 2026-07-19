import '../events/game_catalog.dart';
import '../events/game_event.dart' show GameEventKind;
import 'league/ddragon.dart';
import 'league/league_match_presentation.dart';
import 'match_presentation.dart';

/// One labeled event group in the auto-clip settings UI: a micro-label
/// (`COMBAT`/`OBJECTIVES`/`MATCH`) plus the [GameEventKind]s it toggles. Lives
/// here (not `widgets/event_matrix.dart`, the only place it's rendered) so a
/// [GameDescriptor.eventGroups] can produce it without the games/ layer
/// depending on ui/widgets — the UI file imports this typedef instead.
typedef EventGroupSpec = ({String label, List<GameEventKind> kinds});

/// League's `enabledEvents` matrix groups (§3.4 of the redesign spec):
/// `manual` is excluded (the hotkey always saves, regardless of this config)
/// and `other` has no group (a generic fallback no source currently emits
/// for League).
const List<GameEventKind> combatEvents = [
  GameEventKind.kill,
  GameEventKind.doubleKill,
  GameEventKind.tripleKill,
  GameEventKind.quadraKill,
  GameEventKind.pentaKill,
  GameEventKind.ace,
];
const List<GameEventKind> objectiveEvents = [
  GameEventKind.dragonKill,
  GameEventKind.dragonSteal,
  GameEventKind.baronKill,
  GameEventKind.baronSteal,
  GameEventKind.turretKill,
  GameEventKind.inhibitorKill,
];
const List<GameEventKind> matchEvents = [
  GameEventKind.victory,
  GameEventKind.defeat,
];

List<EventGroupSpec> _leagueEventGroups() => const [
      (label: 'COMBAT', kinds: combatEvents),
      (label: 'OBJECTIVES', kinds: objectiveEvents),
      (label: 'MATCH', kinds: matchEvents),
    ];

List<EventGroupSpec> _noEventGroups() => const [];

MatchPresentation? _noPresentation({DDragon? ddragon}) => null;

/// The hub detail-line copy for a `DetectionMethod.liveClientApi` game (see
/// `GameHubScreen._detailLine`) — the one place vendor-specific prose
/// ("connected to 127.0.0.1:2999") survives outside the descriptor. Every
/// [GameDescriptor] with [GameDescriptor.hasLiveFeed] true must set this
/// (enforced by an assert in the constructor); games without a live feed
/// never read it.
class LiveApiDetailCopy {
  /// The vendor-API half is actually active (a match is live).
  final String inMatch;

  /// Only the process-watch half is active (client open, no match yet).
  final String clientOpenWaiting;

  /// Neither half is active.
  final String waitingForMatch;

  const LiveApiDetailCopy({
    required this.inMatch,
    required this.clientOpenWaiting,
    required this.waitingForMatch,
  });
}

/// Everything about a game integration that used to be hand-duplicated
/// across `match_presentation.dart`, `ui/game_directory.dart`,
/// `ui/game_hub_screen.dart`, and `ui/supported_games_screen.dart` — each
/// with its own private League-id constants and bespoke merge logic (Task
/// 21). One descriptor per DEVIATING game lives in [gameDescriptors]; every
/// call site resolves through [descriptorFor] instead of hardcoding ids.
class GameDescriptor {
  /// The id this game's directory/hub row is keyed by — for a merged game
  /// (League) that's the vendor-API id, never a catalog id.
  final String primaryGameId;

  /// Every gameId that renders as this ONE game. Exactly one id for a plain
  /// catalog/process-detected game; more than one only when a vendor
  /// integration and a [CatalogGame] both exist for the same real game
  /// (League: the vendor id + `app:league_of_legends`) and must be shown
  /// merged rather than as two rows (see `ui/game_directory.dart`'s doc).
  final Set<String> mergedGameIds;

  final String displayName;

  /// Whether this game's real, OS-extracted app icon is safe to show as-is.
  /// `false` means the icon IS a forbidden official logo — Riot's policy on
  /// League; Marvel Rivals conservatively, absent a fan-tool carve-out from
  /// Marvel/Disney/NetEase — and the UI falls back to the FNV-monogram tile.
  /// Default `true`: most catalog games have no such restriction.
  ///
  /// NOTE the polarity is the OPPOSITE of the free function
  /// `usesOfficialLogo()` in `ui/capture_app_match.dart`, which answers "would
  /// showing this app's icon BE using a forbidden logo" (`true` = forbidden).
  /// That function now derives its answer from
  /// `!descriptorFor(gameId).usesOfficialLogo` — see its doc comment.
  final bool usesOfficialLogo;

  /// The match drill-down's per-game presentation (see `match_presentation.
  /// dart`), or a factory that always returns null for a game with none.
  final MatchPresentation? Function({DDragon? ddragon}) presentationFactory;

  /// The auto-clip settings event taxonomy for this game — a function
  /// (rather than a const list) so it can reference top-level consts.
  final List<EventGroupSpec> Function() eventGroups;

  /// Whether the hub's live-events card and `DetectionMethod.liveClientApi`
  /// apply to this game — only League today (see `docs/COMPLIANCE.md`:
  /// process-watched games have no sanctioned event API).
  final bool hasLiveFeed;

  /// Required whenever [hasLiveFeed] is true; unused otherwise.
  final LiveApiDetailCopy? detailCopy;

  const GameDescriptor({
    required this.primaryGameId,
    required this.mergedGameIds,
    required this.displayName,
    this.usesOfficialLogo = true,
    this.presentationFactory = _noPresentation,
    this.eventGroups = _noEventGroups,
    this.hasLiveFeed = false,
    this.detailCopy,
  }) : assert(!hasLiveFeed || detailCopy != null,
            'a live-feed descriptor must supply detailCopy');
}

const _leagueVendorId = 'league_of_legends';
const _leagueCatalogId = 'app:league_of_legends';

/// The registry of games whose behavior DEVIATES from the generic
/// process-detection default — [descriptorFor] synthesizes a default
/// descriptor from [popularGamesCatalog] for every game NOT listed here, so
/// a plain catalog addition (most new games) needs no entry at all. Only add
/// an entry when a game needs a merged id set, a match presentation, event
/// groups, a live feed, or a `usesOfficialLogo` override.
final List<GameDescriptor> gameDescriptors = [
  GameDescriptor(
    primaryGameId: _leagueVendorId,
    mergedGameIds: const {_leagueVendorId, _leagueCatalogId},
    displayName: 'League of Legends',
    usesOfficialLogo: false,
    presentationFactory: ({DDragon? ddragon}) =>
        LeagueMatchPresentation(ddragon: ddragon),
    eventGroups: _leagueEventGroups,
    hasLiveFeed: true,
    detailCopy: const LiveApiDetailCopy(
      inMatch: 'In match — connected to 127.0.0.1:2999',
      clientOpenWaiting: 'Client open — waiting for a match. Rewind connects '
          'automatically when one starts.',
      waitingForMatch: 'Waiting for a match. Detection is automatic — start '
          'a game and Rewind connects.',
    ),
  ),
  const GameDescriptor(
    primaryGameId: 'app:marvel_rivals',
    mergedGameIds: {'app:marvel_rivals'},
    displayName: 'Marvel Rivals',
    // Marvel/Disney/NetEase publish no fan-tool logo carve-out (unlike
    // Riot's explicit "art assets OK, logos not" policy) — stay
    // conservative and never surface the real, OS-extracted app icon.
    usesOfficialLogo: false,
  ),
];

/// Resolves the descriptor for [gameId]: an exact [gameDescriptors] entry
/// whose [GameDescriptor.mergedGameIds] contains it, else a default
/// descriptor synthesized from the matching [popularGamesCatalog] entry (or,
/// for a fully unrecognized id, from [gameId] alone) — see [gameDescriptors]'
/// doc for the "registry holds only deviations" contract.
GameDescriptor descriptorFor(String gameId) {
  for (final d in gameDescriptors) {
    if (d.mergedGameIds.contains(gameId)) return d;
  }
  final catalogMatch = popularGamesCatalog.where((g) => g.gameId == gameId);
  return GameDescriptor(
    primaryGameId: gameId,
    mergedGameIds: {gameId},
    displayName: catalogMatch.isNotEmpty
        ? catalogMatch.first.displayName
        : titleCaseGameId(gameId),
  );
}
