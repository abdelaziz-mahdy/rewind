import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../clip/duration_prober.dart';
import '../clip/match_export.dart';
import '../clip/match_stats.dart';
import '../clip/thumbnail_cache.dart';
import '../coordinator/clip_coordinator.dart';
import '../events/game_catalog.dart';
import '../events/game_event.dart';
import '../games/game_descriptor.dart';
import '../games/league/ddragon.dart';
import '../games/match_presentation.dart';
import '../settings/app_settings.dart';
import '../settings/game_config.dart';
import 'clip_sessions.dart';
import 'game_directory.dart';
import 'match_clips_screen.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';
import 'widgets/event_matrix.dart';
import 'widgets/game_tile_avatar.dart';
import 'widgets/session_card.dart';

/// League has two gameIds in play (see `game_directory.dart`'s own doc on
/// this): the vendor integration that drives auto-clip-on-event, and the
/// catalog's generic process-detection entry. `buildGameDirectory` merges
/// them into one directory row keyed by the vendor id; this hub mirrors that
/// merge for its *clip list* (clips filed under either id belong to the one
/// League hub) via the same [GameDescriptor] registry `game_directory.dart`
/// uses, rather than a second hardcoded copy of League's ids (Task 21).
Set<String> _matchIdsFor(String gameId) => descriptorFor(gameId).mergedGameIds;

/// The Game Hub (§3.4) — the centerpiece of the game-as-entry-point IA.
///
/// Progressive disclosure (maintainer review, "best UI/UX is not show all
/// info"): the hub used to front-load a standalone integration-status card
/// before clips — but that card's headline (e.g. "MANUAL CAPTURE") just
/// repeated the header's status pill, and the settings card pushed clips
/// below the fold. Now: header (avatar/name/status pill/stats + one muted
/// detail line folded in from the old card) → a glanceable capture-settings
/// summary card (buffer/auto-clip/event-count chips, tap to edit in full-page
/// Settings — see `onEditCaptureSettings`) → the clip list, immediately
/// visible. The v0.2 live-events feed slot keeps its own card (it's dynamic,
/// session-scoped content, not a static repeat of the header) and stays
/// hidden until data arrives, unchanged.
///
/// [gameId] rather than a precomputed [GameEntry] is deliberate: the header
/// stats and the active dot all need to react live to clip/activity changes
/// (a new clip landing, a match starting) exactly like the rail does — see
/// `widgets/nav_rail.dart`'s identical `buildGameDirectory` re-derivation
/// under a `ListenableBuilder`.
class GameHubScreen extends StatefulWidget {
  final String gameId;
  final ClipLibrary library;
  final ClipCoordinator coordinator;
  final String hotkeyLabel;
  final ThumbnailCache? thumbnails;

  /// Source of champion/item art for match cards/detail. Null (every test
  /// that doesn't care about art, and any build before `main.dart` threads
  /// one through) always renders the monogram/blank fallbacks.
  final DDragon? ddragon;

  /// Persists a settings change (mutated in place) — the same
  /// `settings.configFor(gameId)` → `setConfig` → `onSettingsChanged` path
  /// the status strip's buffer quick-set uses.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// The capture-settings summary card's tap target: editing now happens on
  /// the full-page Settings screen, opened directly on this game's MY GAMES
  /// page (see `Shell`, which wires this to
  /// `SettingsDestination(initialGameId: gameId)`).
  final VoidCallback onEditCaptureSettings;

  /// Bumped after every settings change (see `Shell.settingsRevision`'s
  /// doc). Edits now happen on a different destination (Settings), not
  /// inline here, so the summary card needs this to notice a change made
  /// while this hub instance stays alive. Optional — every existing test
  /// that doesn't care loses live refresh, not the card itself.
  final ValueListenable<int>? settingsRevision;

  const GameHubScreen({
    required this.gameId,
    required this.library,
    required this.coordinator,
    required this.hotkeyLabel,
    required this.onSettingsChanged,
    required this.onEditCaptureSettings,
    this.settingsRevision,
    this.thumbnails,
    this.ddragon,
    super.key,
  });

  @override
  State<GameHubScreen> createState() => _GameHubScreenState();
}

class _GameHubScreenState extends State<GameHubScreen> {
  /// Only a descriptor with [GameDescriptor.hasLiveFeed] ever emits
  /// `GameEvent`s (see `docs/COMPLIANCE.md` — process-watched catalog games
  /// have no sanctioned event API) — League is the only one today, but this
  /// no longer hardcodes its id (Task 21).
  bool get _isLeague => descriptorFor(widget.gameId).hasLiveFeed;

  StreamSubscription<GameEvent>? _eventsSub;
  final List<GameEvent> _liveEvents = [];

  @override
  void initState() {
    super.initState();
    if (_isLeague) {
      _eventsSub = widget.coordinator.registry.events
          .where((e) =>
              e.gameId == widget.gameId &&
              // matchInfo/statsUpdate are metadata, not a live moment for
              // the feed — statsUpdate in particular fires every poll
              // (~500 ms) and would otherwise spam it.
              e.kind != GameEventKind.matchInfo &&
              e.kind != GameEventKind.statsUpdate)
          .listen((e) {
        setState(() {
          _liveEvents.insert(0, e);
          if (_liveEvents.length > 20) _liveEvents.removeLast();
        });
      });
    }
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }

  /// Read-only snapshot of this game's config, recomputed fresh on every
  /// build for the summary card — unlike `AppSettings.configFor`, this never
  /// creates/persists a row just because the hub was opened; a fresh
  /// `GameConfig(gameId: ...)` mirrors exactly what `configFor` would
  /// lazily create on the first real edit (now made on the Settings screen,
  /// not here).
  GameConfig _configSnapshot() {
    final settings = widget.coordinator.settings;
    final existing =
        settings.allConfigs.where((c) => c.gameId == widget.gameId);
    return existing.isNotEmpty
        ? existing.first
        : GameConfig(
            gameId: widget.gameId,
            bufferSeconds: settings.bufferSecondsFor(widget.gameId),
          );
  }

  /// [buildGameDirectory] only surfaces a merged row once it has a config, a
  /// clip, or live activity (§3.5's presence gate) — but this hub is the
  /// vendor-integrated hub regardless of whether any of those have happened
  /// *yet*. Falling back to an empty-detection stub in that window would
  /// misreport the integration card as "Manual capture" for a game that very
  /// much has a Live Client API integration, so a [GameDescriptor.hasLiveFeed]
  /// game gets its own synthesized fallback (generalized from League's,
  /// Task 21) instead of the generic empty one.
  GameEntry _resolveEntry(List<GameEntry> entries) {
    final found = entries.where((e) => e.gameId == widget.gameId);
    if (found.isNotEmpty) return found.first;
    final descriptor = descriptorFor(widget.gameId);
    if (descriptor.hasLiveFeed) {
      final catalogMatch = popularGamesCatalog
          .where((g) => descriptor.mergedGameIds.contains(g.gameId))
          .map((g) => g.processMatch);
      return GameEntry(
        gameId: widget.gameId,
        displayName: displayNameFor(widget.gameId),
        detection: const {
          DetectionMethod.liveClientApi,
          DetectionMethod.processWatch,
        },
        processMatch: catalogMatch.isNotEmpty ? catalogMatch.first : null,
        active: false,
        clipCount: 0,
        totalSizeBytes: 0,
      );
    }
    return GameEntry(
      gameId: widget.gameId,
      displayName: displayNameFor(widget.gameId),
      detection: const {},
      active: false,
      clipCount: 0,
      totalSizeBytes: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge([
      widget.library,
      widget.coordinator.activeGameIds,
      // Live K/D: match cards must re-render as kills/deaths land.
      if (widget.coordinator.matchStats != null) widget.coordinator.matchStats!,
      // The summary card's buffer/auto-clip/event-count chips: edits now
      // happen on the Settings destination, not inline here, so this hub
      // must be told when to re-read `_configSnapshot()`.
      if (widget.settingsRevision != null) widget.settingsRevision!,
    ]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final entries = buildGameDirectory(
          settings: widget.coordinator.settings,
          clips: widget.library.all,
          activeIds: widget.coordinator.activeGameIds.value,
        );
        final entry = _resolveEntry(entries);

        final matchIds = _matchIdsFor(widget.gameId);
        final clips = widget.library.all
            .where((c) => matchIds.contains(c.gameId))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        // One card per play session (match). A game with an in-match API
        // (League) labels them MATCH and can show K/D; process-detected
        // games and desktop label them SESSION.
        final sessions = groupClipsIntoSessions(clips);
        final isMatch = entry.detection.contains(DetectionMethod.liveClientApi);

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _header(context, entry, _scoreCells(entry, sessions)),
            if (_isLeague && _liveEvents.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: _liveEventsCard(context),
              ),
            // Placed right under the header, not at the bottom: the match
            // list can grow unbounded, and burying settings behind it would
            // hurt discoverability far more than a single summary row costs
            // the "clips first" goal (see the class doc). Collapsed =
            // summarized, never hidden — the card always shows the current
            // config; tapping it is the only way to change it now.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: _captureSummaryCard(context, entry),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
              child: Text(isMatch ? 'Matches' : 'Sessions',
                  style: Theme.of(context).textTheme.title),
            ),
            if (sessions.isEmpty)
              _EmptyGameClips(
                  displayName: entry.displayName,
                  hotkeyLabel: widget.hotkeyLabel,
                  onEditCaptureSettings: widget.onEditCaptureSettings)
            else
              // Keyed 'clipsList' so the pre-existing list-scoped test
              // finders keep working across the clip-grid → match-grid
              // change.
              Padding(
                key: const ValueKey('clipsList'),
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                child: LayoutBuilder(
                  builder: (context, constraints) => GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent:
                          clipGridExtentFor(constraints.maxWidth),
                      mainAxisSpacing: clipGridSpacing,
                      crossAxisSpacing: clipGridSpacing,
                      childAspectRatio: sessionCardAspectRatio,
                    ),
                    itemCount: sessions.length,
                    itemBuilder: (context, i) {
                      final session = sessions[i];
                      return SessionCard(
                        session: session,
                        isMatch: isMatch,
                        stats: widget.coordinator.matchStats
                            ?.statsFor(widget.gameId, session.startedAt),
                        thumbnails: widget.thumbnails,
                        ddragon: widget.ddragon,
                        onTap: () => _openMatch(context, entry, session),
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _openMatch(BuildContext context, GameEntry entry, ClipSession session) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: matchClipsScreenRouteName),
      builder: (_) => MatchClipsScreen(
        exporter: FfmpegMatchExporter(),
        prober: FfprobeDurationProber(),
        session: session,
        matchLabel: _sessionLabel(entry, session),
        stats: widget.coordinator.matchStats
            ?.statsFor(widget.gameId, session.startedAt),
        library: widget.library,
        thumbnails: widget.thumbnails,
        presentation:
            matchPresentationFor(widget.gameId, ddragon: widget.ddragon),
      ),
    ));
  }

  Widget _header(
      BuildContext context, GameEntry entry, List<_ScoreCell> cells) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GameTileAvatar(
                gameId: entry.gameId,
                displayName: entry.displayName,
                size: 40,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  entry.displayName,
                  key: const ValueKey('gameHubTitle'),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.display,
                ),
              ),
              const SizedBox(width: 12),
              _StatusPill(entry: entry),
            ],
          ),
          const SizedBox(height: 8),
          // The one useful line from the old standalone integration card
          // (§ progressive disclosure): everything else that card said
          // (the detection-method name) is already the status pill above,
          // so only the dynamic status detail is worth a second line.
          Text(
            _detailLine(entry),
            key: const ValueKey('gameHubDetailLine'),
            style: theme.textTheme.bodyMuted,
          ),
          // No fake stats: the band only appears once this game has a clip,
          // and each cell is omitted rather than shown as zero when the
          // underlying data was never recorded.
          if (entry.clipCount > 0) ...[
            const SizedBox(height: 12),
            _ScoreBand(cells: cells),
          ],
        ],
      ),
    );
  }

  /// The header's four-cell readout — the reason to open a hub at all.
  ///
  /// A hub used to end its header with "42 clips · 2.4 GB · last clip 2 h
  /// ago": true, but it never answered the question a player actually opens
  /// their own match history to ask. With recorded stats the band reports
  /// matches, win rate and average KDA; without them it falls back to what
  /// IS known. Nothing is invented — a cell whose data was never recorded is
  /// left out rather than rendered as a zero.
  List<_ScoreCell> _scoreCells(GameEntry entry, List<ClipSession> sessions) {
    final store = widget.coordinator.matchStats;
    final recorded = <MatchStats>[
      if (store != null)
        for (final s in sessions)
          if (store.statsFor(widget.gameId, s.startedAt) case final m?) m,
    ];
    final decided = recorded.where((m) => m.result != null).toList();
    final combat =
        recorded.where((m) => m.kills > 0 || m.deaths > 0 || m.assists > 0);

    final cells = <_ScoreCell>[
      _ScoreCell(
        value: '${sessions.length}',
        label: recorded.isEmpty ? 'SESSIONS' : 'MATCHES',
      ),
    ];

    // A RECORD, never a win-rate percentage.
    //
    // Rewind records a match outcome only when it is still watching at the
    // end of the match, which in practice is the minority: on a real library
    // (2026-07-25) 19 of 21 matches had no result at all, and both that did
    // were wins — so a percentage rendered "100% WIN RATE" off a sample of
    // two. A percentage hides its own denominator, which is exactly the
    // wrong property for a figure this sparse. "2-0", with the sample spelled
    // out whenever some matches are unrated, cannot lie the same way.
    if (decided.isNotEmpty) {
      final wins = decided.where((m) => m.result == MatchResult.win).length;
      final losses = decided.length - wins;
      final complete = decided.length == sessions.length;
      cells.add(_ScoreCell(
        value: '$wins-$losses',
        label: complete
            ? 'RECORD'
            : 'RECORD · ${decided.length} OF ${sessions.length}',
        positive: wins > losses,
      ));
    }

    if (combat.isNotEmpty) {
      final k = combat.fold<int>(0, (n, m) => n + m.kills);
      final d = combat.fold<int>(0, (n, m) => n + m.deaths);
      final a = combat.fold<int>(0, (n, m) => n + m.assists);
      // The conventional KDA ratio. A no-death run divides by 1 rather than
      // reporting infinity, which is the same convention every scoreboard
      // the user has seen already uses.
      final kda = (k + a) / (d == 0 ? 1 : d);
      cells.add(_ScoreCell(value: kda.toStringAsFixed(1), label: 'AVG KDA'));
    }

    cells.add(
        _ScoreCell(value: formatSize(entry.totalSizeBytes), label: 'ON DISK'));

    if (cells.length < 4) {
      if (entry.lastClipAt case final last?) {
        cells.add(_ScoreCell(
            value: relativeAge(last).toUpperCase(), label: 'LAST CLIP'));
      }
    }
    return cells;
  }

  /// The single line folded in from the old integration-status card: for
  /// League, its live/waiting-for-match status; for a catalog game, whether
  /// its process is currently seen running; for `desktop`, the hotkey hint.
  /// Static explanatory notes the card also used to show (e.g. "no event
  /// API for this game") are intentionally dropped here — one line only.
  /// A session group's header: "MATCH · 2 h ago · 3 CLIPS" for games with a
  /// real in-match API, "SESSION · …" for everything else (process-detected
  /// games and the desktop pseudo-game, where "match" would overclaim).
  String _sessionLabel(GameEntry entry, ClipSession session) {
    final word = entry.detection.contains(DetectionMethod.liveClientApi)
        ? 'MATCH'
        : 'SESSION';
    final count = session.clips.length;
    return '$word · ${relativeAge(session.startedAt).toUpperCase()} · '
        '$count ${count == 1 ? 'CLIP' : 'CLIPS'}';
  }

  String _detailLine(GameEntry entry) {
    if (entry.detection.contains(DetectionMethod.liveClientApi)) {
      // A merged row (League) is `active` when EITHER half fires; only the
      // vendor-API half being active means an actual match. The client
      // sitting in the lobby used to read "In match — connected to
      // 127.0.0.1:2999" while nothing was listening on 2999 at all. The
      // actual prose now lives on the descriptor (Task 21) — only the
      // active/vendorActive branching stays generic here.
      final copy = descriptorFor(entry.gameId).detailCopy!;
      if (entry.vendorActive) return copy.inMatch;
      return entry.active ? copy.clientOpenWaiting : copy.waitingForMatch;
    }
    if (entry.detection.contains(DetectionMethod.processWatch)) {
      return entry.active
          ? 'Running now'
          : 'Watching for ${entry.processMatch}';
    }
    return 'Clips saved with ${widget.hotkeyLabel} while no game is detected.';
  }

  Widget _liveEventsCard(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return _Card(
      key: const ValueKey('liveEventsSlot'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LIVE EVENTS',
              style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
          const SizedBox(height: 10),
          // Compact wrap of chips instead of one full-width row per event —
          // fills the card's width and stays short (the old list left most
          // of the card empty and grew tall). Cap the visible count; the
          // full history lives in each clip anyway.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _liveEvents.take(12)) _LiveEventChip(event: e),
            ],
          ),
        ],
      ),
    );
  }

  /// The glanceable capture-settings summary card (§ "collapsed = summarized,
  /// never hidden" — the user must be able to READ their config from the hub
  /// without opening anything, and only leaves the hub to CHANGE it). One
  /// bounded, tappable row-card: a micro-label plus chips reporting the
  /// buffer length and — only for games with an event source
  /// ([eventGroupsFor]) — the auto-clip on/off state and enabled-event count.
  /// The whole card opens Settings on this game's MY GAMES page via
  /// [GameHubScreen.onEditCaptureSettings]; there is no inline editing here
  /// anymore (see `settings_screen.dart`'s `_GameSettingsPage`).
  Widget _captureSummaryCard(BuildContext context, GameEntry entry) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final cfg = _configSnapshot();
    final groups = eventGroupsFor(entry);
    final showAutoClip = groups.isNotEmpty;
    // `enabledEvents` always carries `manual` (see GameConfig's default —
    // the hotkey always saves regardless of this config), which never
    // appears as a toggle in any group; count only kinds the matrix itself
    // can show/hide so this number matches what's actually checked there.
    final matrixKinds = groups.expand((g) => g.kinds).toSet();
    final enabledEventCount =
        cfg.enabledEvents.intersection(matrixKinds).length;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: settingsMaxContentWidth),
      child: Container(
        key: const ValueKey('captureSummaryCard'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          border: Border.fromBorderSide(hairlineBorder()),
        ),
        // The border/clip live on this outer Container so the InkWell's
        // hover/press overlay (painted by the Material below, atop its own
        // `color`) stays visible instead of being painted underneath an
        // opaque child — see EventToggleChip's identical Material→InkWell
        // ordering for the same reason.
        child: Material(
          color: tokens.surface,
          child: InkWell(
            onTap: widget.onEditCaptureSettings,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('CAPTURE SETTINGS',
                            style: theme.textTheme.micro
                                .copyWith(color: tokens.textMuted)),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _SummaryChip(
                                label:
                                    '${widget.coordinator.settings.bufferSecondsFor(widget.gameId)} s buffer'),
                            if (showAutoClip)
                              _SummaryChip(
                                key: const ValueKey('captureSummaryAutoClip'),
                                label: cfg.autoClip
                                    ? 'Auto-clip ON'
                                    : 'Auto-clip OFF',
                                // `armed`: auto-clip being on is a standing
                                // machine state, not a selection.
                                color: cfg.autoClip
                                    ? tokens.armed
                                    : tokens.textMuted,
                              ),
                            if (showAutoClip && cfg.autoClip)
                              _SummaryChip(label: '$enabledEventCount events'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('Edit',
                      style: theme.textTheme.label
                          .copyWith(color: tokens.textMuted)),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right, size: 18, color: tokens.textMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One cell of the hub header's score band.
class _ScoreCell {
  final String value;
  final String label;

  /// Tints the value with `positive` — used only where a higher number is
  /// unambiguously better (a win rate at or above 50%).
  final bool positive;

  const _ScoreCell(
      {required this.value, required this.label, this.positive = false});
}

/// The hub header's readout: up to four hairline-separated cells, numerals
/// in the mono face so they align and read as data rather than prose.
class _ScoreBand extends StatelessWidget {
  final List<_ScoreCell> cells;

  const _ScoreBand({required this.cells});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: settingsMaxContentWidth),
      child: Container(
        key: const ValueKey('gameHubScoreBand'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          border: Border.fromBorderSide(hairlineBorder()),
          color: tokens.surface,
        ),
        child: Row(
          children: [
            for (var i = 0; i < cells.length; i++)
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: i == 0
                      ? null
                      : BoxDecoration(
                          border: Border(left: hairlineBorder()),
                        ),
                  child: Semantics(
                    label: '${cells[i].label.toLowerCase()} '
                        '${cells[i].value}',
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cells[i].value,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: theme.textTheme.numeralLarge.copyWith(
                              fontSize: 19,
                              color: cells[i].positive
                                  ? tokens.positive
                                  : tokens.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            cells[i].label,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: theme.textTheme.micro
                                .copyWith(color: tokens.textDim),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One summary chip in [_GameHubScreenState._captureSummaryCard]: a small
/// raised-bg pill, same visual language as [_StatusPill].
class _SummaryChip extends StatelessWidget {
  final String label;
  final Color? color;

  const _SummaryChip({required this.label, this.color, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(tokens.radiusChip),
        border: Border.fromBorderSide(hairlineBorder()),
      ),
      child: Text(label,
          style: theme.textTheme.micro.copyWith(color: color ?? tokens.text)),
    );
  }
}

/// A small rectangular pill in the header: a live/muted dot + the detection
/// method's name, so a glance at the hub tells you how this game is
/// integrated without reading the whole integration card.
class _StatusPill extends StatelessWidget {
  final GameEntry entry;

  const _StatusPill({required this.entry});

  /// What the user GETS, not how Rewind is built.
  ///
  /// This used to read "LIVE CLIENT API" / "PROCESS DETECTION" / "MANUAL
  /// CAPTURE" — implementation vocabulary that tells a player nothing they
  /// can act on. The distinction that matters to them is whether the game
  /// clips itself, whether Rewind at least knows when they're playing, or
  /// whether it's hotkey-only.
  String get _label {
    if (entry.detection.contains(DetectionMethod.liveClientApi)) {
      return entry.vendorActive ? 'IN MATCH · CLIPS ITSELF' : 'CLIPS ITSELF';
    }
    if (entry.detection.contains(DetectionMethod.processWatch)) {
      return entry.active
          ? 'RUNNING · KNOWS WHEN YOU PLAY'
          : 'KNOWS WHEN YOU PLAY';
    }
    return 'HOTKEY ONLY';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final color = entry.active ? tokens.armed : tokens.textDim;
    return Semantics(
      label: entry.active ? '$_label, active now' : _label,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: BorderRadius.circular(tokens.radiusChip),
            border: Border.fromBorderSide(hairlineBorder()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const SizedBox(width: 6, height: 6),
              ),
              const SizedBox(width: 6),
              Text(_label, style: theme.textTheme.micro.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row in the v0.2 live-events feed slot: badge + relative age, styled
/// like `ClipTile`'s own event badge.
/// A compact live-event chip: the event badge with its age tucked to the
/// right, wrapped into a flowing row so the feed stays short and dense.
class _LiveEventChip extends StatelessWidget {
  final GameEvent event;

  const _LiveEventChip({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EventBadge(kind: event.kind),
        const SizedBox(width: 6),
        Text(relativeAge(event.time),
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
      ],
    );
  }
}

/// A hairline-bordered card — used for the live-events feed slot (the
/// capture-settings summary card draws its own near-identical shape inline,
/// see `_captureSummaryCard`, and the old standalone integration status card
/// folded into the header, § progressive disclosure). Matches `_Section`'s
/// treatment in the (embedded) Settings destination.
class _Card extends StatelessWidget {
  final Widget child;

  const _Card({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        border: Border.fromBorderSide(hairlineBorder()),
      ),
      child: child,
    );
  }
}

class _EmptyGameClips extends StatelessWidget {
  final String displayName;
  final String hotkeyLabel;
  final VoidCallback onEditCaptureSettings;

  const _EmptyGameClips({
    required this.displayName,
    required this.hotkeyLabel,
    required this.onEditCaptureSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = context.rewindTokens.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          children: [
            Text(
              'No $displayName clips yet — press $hotkeyLabel during a game.',
              textAlign: TextAlign.center,
              style: theme.textTheme.body.copyWith(color: muted),
            ),
            const SizedBox(height: 16),
            // An action so a zero-clip hub isn't a dead end: auto-clipping
            // and buffer length live in this game's capture settings, the
            // usual reason nothing has been clipped yet.
            OutlinedButton(
              key: const ValueKey('emptyGameEditSettings'),
              onPressed: onEditCaptureSettings,
              child: const Text('Edit capture settings'),
            ),
          ],
        ),
      ),
    );
  }
}
