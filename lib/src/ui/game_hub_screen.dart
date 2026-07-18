import 'dart:async';

import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../clip/thumbnail_cache.dart';
import '../coordinator/clip_coordinator.dart';
import '../events/game_catalog.dart';
import '../events/game_event.dart';
import '../games/league/ddragon.dart';
import '../settings/app_settings.dart';
import '../settings/game_config.dart';
import 'clip_sessions.dart';
import 'game_directory.dart';
import 'match_clips_screen.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';
import 'widgets/event_matrix.dart';
import 'widgets/game_tile_avatar.dart';
import 'widgets/match_card.dart';
import 'widgets/setting_row.dart';

/// League has two gameIds in play (see `game_directory.dart`'s own doc on
/// this): the vendor integration that drives auto-clip-on-event, and the
/// catalog's generic process-detection entry. `buildGameDirectory` merges
/// them into one directory row keyed by the vendor id; this hub mirrors that
/// merge for its *clip list* (clips filed under either id belong to the one
/// League hub) — kept in sync with that file's `_leagueVendorId`/
/// `_leagueCatalogId` constants by hand, since those are private to it.
const _leagueVendorId = 'league_of_legends';
const _leagueCatalogId = 'app:league_of_legends';

Set<String> _matchIdsFor(String gameId) => gameId == _leagueVendorId
    ? const {_leagueVendorId, _leagueCatalogId}
    : {gameId};

/// The Game Hub (§3.4) — the centerpiece of the game-as-entry-point IA.
///
/// Progressive disclosure (maintainer review, "best UI/UX is not show all
/// info"): the hub used to front-load a standalone integration-status card
/// before clips — but that card's headline (e.g. "MANUAL CAPTURE") just
/// repeated the header's status pill, and the settings card pushed clips
/// below the fold. Now: header (avatar/name/status pill/stats + one muted
/// detail line folded in from the old card) → a collapsed-by-default
/// "Capture settings" disclosure (buffer/auto-clip/events, expands inline on
/// tap) → the clip list, immediately visible. The v0.2 live-events feed slot
/// keeps its own card (it's dynamic, session-scoped content, not a static
/// repeat of the header) and stays hidden until data arrives, unchanged.
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

  const GameHubScreen({
    required this.gameId,
    required this.library,
    required this.coordinator,
    required this.hotkeyLabel,
    required this.onSettingsChanged,
    this.thumbnails,
    this.ddragon,
    super.key,
  });

  @override
  State<GameHubScreen> createState() => _GameHubScreenState();
}

class _GameHubScreenState extends State<GameHubScreen> {
  late int _bufferSeconds;
  late bool _customBuffer;
  late final TextEditingController _bufferController;
  late bool _autoClip;
  late Set<GameEventKind> _enabledEvents;

  /// Whether the "Capture settings" disclosure is open. Collapsed by
  /// default (§ progressive disclosure) and deliberately not persisted —
  /// reopening it every visit is a fine YAGNI tradeoff for a rarely-touched
  /// per-game section.
  bool _settingsExpanded = false;

  /// Only League's vendor integration ever emits `GameEvent`s (see
  /// `docs/COMPLIANCE.md` — process-watched catalog games have no sanctioned
  /// event API), so the live-events slot and the auto-clip event matrix only
  /// ever apply to it.
  bool get _isLeague => widget.gameId == _leagueVendorId;

  StreamSubscription<GameEvent>? _eventsSub;
  final List<GameEvent> _liveEvents = [];

  @override
  void initState() {
    super.initState();
    _initLocalConfigState();
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

  /// Seeds local editable state from any existing [GameConfig] — read-only
  /// (unlike `AppSettings.configFor`, this never creates/persists a row just
  /// because the hub was opened; a fresh `GameConfig(gameId: ...)` mirrors
  /// exactly what `configFor` would lazily create on the first real edit).
  void _initLocalConfigState() {
    final settings = widget.coordinator.settings;
    final existing =
        settings.allConfigs.where((c) => c.gameId == widget.gameId);
    final snapshot = existing.isNotEmpty
        ? existing.first
        : GameConfig(
            gameId: widget.gameId,
            bufferSeconds: settings.bufferSecondsFor(widget.gameId),
          );
    _bufferSeconds = snapshot.bufferSeconds;
    _customBuffer =
        _bufferSeconds != 15 && _bufferSeconds != 30 && _bufferSeconds != 60;
    _bufferController = TextEditingController(text: '$_bufferSeconds');
    _autoClip = snapshot.autoClip;
    _enabledEvents = Set.of(snapshot.enabledEvents);
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _bufferController.dispose();
    super.dispose();
  }

  void _commitBuffer(int seconds) {
    setState(() {
      _bufferSeconds = seconds;
      _customBuffer = false;
    });
    final settings = widget.coordinator.settings;
    final cfg = settings.configFor(widget.gameId);
    cfg.bufferSeconds = seconds;
    settings.setConfig(cfg);
    widget.onSettingsChanged(settings);
  }

  void _handleCustomBufferChanged(String value) {
    final clamped =
        (int.tryParse(value) ?? _bufferSeconds).clamp(5, 300).toInt();
    setState(() => _bufferSeconds = clamped);
    if (_bufferController.text != '$clamped') {
      _bufferController.text = '$clamped';
    }
    final settings = widget.coordinator.settings;
    final cfg = settings.configFor(widget.gameId);
    cfg.bufferSeconds = clamped;
    settings.setConfig(cfg);
    widget.onSettingsChanged(settings);
  }

  void _setAutoClip(bool value) {
    setState(() => _autoClip = value);
    final settings = widget.coordinator.settings;
    final cfg = settings.configFor(widget.gameId);
    cfg.autoClip = value;
    settings.setConfig(cfg);
    widget.onSettingsChanged(settings);
  }

  void _toggleEvent(GameEventKind kind, bool value) {
    setState(() {
      if (value) {
        _enabledEvents.add(kind);
      } else {
        _enabledEvents.remove(kind);
      }
    });
    final settings = widget.coordinator.settings;
    final cfg = settings.configFor(widget.gameId);
    cfg.enabledEvents = Set.of(_enabledEvents);
    settings.setConfig(cfg);
    widget.onSettingsChanged(settings);
  }

  /// [buildGameDirectory] only surfaces League's merged row once it has a
  /// config, a clip, or live activity (§3.5's `hasLeague` gate) — but this
  /// hub is the vendor-integrated League hub regardless of whether any of
  /// those have happened *yet*. Falling back to an empty-detection stub in
  /// that window would misreport the integration card as "Manual capture"
  /// for a game that very much has a Live Client API integration, so League
  /// gets its own synthesized fallback instead of the generic empty one.
  GameEntry _resolveEntry(List<GameEntry> entries) {
    final found = entries.where((e) => e.gameId == widget.gameId);
    if (found.isNotEmpty) return found.first;
    if (_isLeague) {
      final catalogMatch = popularGamesCatalog
          .where((g) => g.gameId == _leagueCatalogId)
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
            _header(context, entry),
            if (_isLeague && _liveEvents.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: _liveEventsCard(context),
              ),
            // Collapsed by default and placed right under the header, not
            // at the bottom: the match list can grow unbounded, and burying
            // settings behind it would hurt discoverability far more than a
            // single ~40px closed disclosure row costs the "clips first"
            // goal (see the class doc).
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: _captureSettingsDisclosure(context),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
              child: Text(isMatch ? 'Matches' : 'Sessions',
                  style: Theme.of(context).textTheme.title),
            ),
            if (sessions.isEmpty)
              _EmptyGameClips(
                  displayName: entry.displayName,
                  hotkeyLabel: widget.hotkeyLabel)
            else
              // Keyed 'clipsList' so the pre-existing list-scoped test
              // finders keep working across the clip-grid → match-grid
              // change.
              Padding(
                key: const ValueKey('clipsList'),
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: clipGridMaxCrossAxisExtent,
                    mainAxisSpacing: clipGridSpacing,
                    crossAxisSpacing: clipGridSpacing,
                    childAspectRatio: matchCardAspectRatio,
                  ),
                  itemCount: sessions.length,
                  itemBuilder: (context, i) {
                    final session = sessions[i];
                    return MatchCard(
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
          ],
        );
      },
    );
  }

  void _openMatch(BuildContext context, GameEntry entry, ClipSession session) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: matchClipsScreenRouteName),
      builder: (_) => MatchClipsScreen(
        session: session,
        matchLabel: _sessionLabel(entry, session),
        stats: widget.coordinator.matchStats
            ?.statsFor(widget.gameId, session.startedAt),
        library: widget.library,
        thumbnails: widget.thumbnails,
        ddragon: widget.ddragon,
      ),
    ));
  }

  Widget _header(BuildContext context, GameEntry entry) {
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
          // No fake stats: the fact row only appears once this game has a
          // clip (§3.4 — "omit facts when zero clips").
          if (entry.clipCount > 0) ...[
            const SizedBox(height: 4),
            Text(_factLine(entry), style: theme.textTheme.bodyMuted),
          ],
        ],
      ),
    );
  }

  String _factLine(GameEntry entry) {
    final base =
        '${entry.clipCount} clips · ${formatSize(entry.totalSizeBytes)}';
    final last = entry.lastClipAt;
    return last == null ? base : '$base · last clip ${relativeAge(last)}';
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
      // 127.0.0.1:2999" while nothing was listening on 2999 at all.
      if (entry.vendorActive) {
        return 'In match — connected to 127.0.0.1:2999';
      }
      return entry.active
          ? 'Client open — waiting for a match. Rewind connects '
              'automatically when one starts.'
          : 'Waiting for a match. Detection is automatic — start a game '
              'and Rewind connects.';
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

  /// The collapsed-by-default "Capture settings" disclosure (§ progressive
  /// disclosure): a compact header row (uppercase micro-label + chevron,
  /// hairline top border acting as a section divider rather than a full
  /// card) that reveals the buffer/auto-clip/event-matrix controls inline.
  /// The content is only built into the tree once expanded — not merely
  /// hidden — so it (and its controls) aren't findable/interactable while
  /// collapsed.
  Widget _captureSettingsDisclosure(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('captureSettingsToggle'),
            onTap: () => setState(() => _settingsExpanded = !_settingsExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: tokens.hairline)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('CAPTURE SETTINGS',
                        style: theme.textTheme.micro
                            .copyWith(color: tokens.textMuted)),
                  ),
                  AnimatedRotation(
                    turns: _settingsExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.expand_more,
                        size: 18, color: tokens.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _settingsExpanded
              ? Padding(
                  key: const ValueKey('captureSettingsBody'),
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  // Same single-column label→control shape as the Settings
                  // screen, so it gets the same cap: left-aligned, not
                  // stretched across the window (which stranded the Auto-clip
                  // toggle a window-width away from its label). The Matches
                  // grid below is deliberately left uncapped.
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                          maxWidth: settingsMaxContentWidth),
                      child: _captureSettingsBody(context),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _captureSettingsBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Same row grammar as the Settings screen (widgets/setting_row.dart):
        // these are the same settings, so they must not have a second shape
        // here. This panel used to draw label-ABOVE-control while Settings
        // drew label-left/control-right.
        SettingRows([
          SettingRow(
            label: 'Buffer length',
            control: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '15', label: Text('15 s')),
                ButtonSegment(value: '30', label: Text('30 s')),
                ButtonSegment(value: '60', label: Text('60 s')),
                ButtonSegment(value: 'custom', label: Text('Custom')),
              ],
              selected: {_customBuffer ? 'custom' : '$_bufferSeconds'},
              onSelectionChanged: (selection) {
                final value = selection.first;
                if (value == 'custom') {
                  setState(() => _customBuffer = true);
                } else {
                  _commitBuffer(int.parse(value));
                }
              },
            ),
          ),
          if (_customBuffer)
            SettingRow(
              label: 'Custom buffer',
              control: SizedBox(
                width: 200,
                child: TextField(
                  key: const ValueKey('gameHubBufferField'),
                  controller: _bufferController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Seconds (5-300)'),
                  onChanged: _handleCustomBufferChanged,
                ),
              ),
            ),
          // Only League emits events (§3.4 — "the only source that emits
          // events"): catalog/desktop games get buffer-only settings, with
          // the event UI hidden entirely rather than shown-and-disabled.
          if (_isLeague)
            SettingRow(
              label: 'Auto-clip',
              hint: Text('Save a clip automatically when one of these happens',
                  style: Theme.of(context).textTheme.bodyMuted),
              control: Switch(
                key: const ValueKey('gameHubAutoClipSwitch'),
                value: _autoClip,
                onChanged: _setAutoClip,
              ),
            ),
        ]),
        if (_isLeague) ...[
          const SizedBox(height: 12),
          Opacity(
            opacity: _autoClip ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !_autoClip,
              child: Column(
                key: const ValueKey('gameHubEventMatrix'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EventGroup(
                    label: 'COMBAT',
                    kinds: combatEvents,
                    selected: _enabledEvents,
                    onChanged: _toggleEvent,
                  ),
                  const SizedBox(height: 12),
                  EventGroup(
                    label: 'OBJECTIVES',
                    kinds: objectiveEvents,
                    selected: _enabledEvents,
                    onChanged: _toggleEvent,
                  ),
                  const SizedBox(height: 12),
                  EventGroup(
                    label: 'MATCH',
                    kinds: matchEvents,
                    selected: _enabledEvents,
                    onChanged: _toggleEvent,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A small rectangular pill in the header: a live/muted dot + the detection
/// method's name, so a glance at the hub tells you how this game is
/// integrated without reading the whole integration card.
class _StatusPill extends StatelessWidget {
  final GameEntry entry;

  const _StatusPill({required this.entry});

  String get _label {
    if (entry.detection.contains(DetectionMethod.liveClientApi)) {
      return 'LIVE CLIENT API';
    }
    if (entry.detection.contains(DetectionMethod.processWatch)) {
      return 'PROCESS DETECTION';
    }
    return 'MANUAL CAPTURE';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final color = entry.active ? tokens.accent : tokens.textMuted;
    return Container(
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

/// A hairline-bordered card — used for the live-events feed slot, the one
/// remaining card in the hub (capture settings and integration status moved
/// to a disclosure/header line, § progressive disclosure). Matches
/// `_Section`'s treatment in the (embedded) Settings destination.
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

  const _EmptyGameClips({required this.displayName, required this.hotkeyLabel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = context.rewindTokens.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(
          'No $displayName clips yet — press $hotkeyLabel during a game.',
          textAlign: TextAlign.center,
          style: theme.textTheme.body.copyWith(color: muted),
        ),
      ),
    );
  }
}
