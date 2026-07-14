import 'dart:async';

import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import '../events/game_catalog.dart';
import '../events/game_event.dart';
import '../settings/app_settings.dart';
import '../settings/game_config.dart';
import 'game_directory.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';
import 'widgets/event_filter_chips.dart';

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

/// League's `enabledEvents` matrix groups (§3.4): `manual` is excluded
/// (the hotkey always saves, regardless of this config) and `other` has no
/// group (it's a generic fallback no source currently emits for League).
const _combatEvents = [
  GameEventKind.kill,
  GameEventKind.doubleKill,
  GameEventKind.tripleKill,
  GameEventKind.quadraKill,
  GameEventKind.pentaKill,
  GameEventKind.ace,
];
const _objectiveEvents = [
  GameEventKind.dragonKill,
  GameEventKind.dragonSteal,
  GameEventKind.baronKill,
  GameEventKind.baronSteal,
  GameEventKind.turretKill,
  GameEventKind.inhibitorKill,
];
const _matchEvents = [GameEventKind.victory, GameEventKind.defeat];

/// The Game Hub (§3.4) — the centerpiece of the game-as-entry-point IA: a
/// header with derived stats, an integration-status card (what Rewind knows
/// about this game and, for League, the v0.2 live-events feed slot), an
/// inline per-game capture-settings card, and this game's scoped clip list.
///
/// [gameId] rather than a precomputed [GameEntry] is deliberate: the header
/// stats, the active dot, and the integration card all need to react live to
/// clip/activity changes (a new clip landing, a match starting) exactly like
/// the rail does — see `widgets/nav_rail.dart`'s identical
/// `buildGameDirectory` re-derivation under a `ListenableBuilder`.
class GameHubScreen extends StatefulWidget {
  final String gameId;
  final ClipLibrary library;
  final ClipCoordinator coordinator;
  final String hotkeyLabel;

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

  /// Selected event-kind filter for the clip list below; null means "All".
  GameEventKind? _filterKind;

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
          .where((e) => e.gameId == widget.gameId)
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
    final listenable =
        Listenable.merge([widget.library, widget.coordinator.activeGameIds]);
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
        final scoped = widget.library.all
            .where((c) => matchIds.contains(c.gameId))
            .toList();
        // Self-healing filter: rather than a separate library listener to
        // reset stale state (as `AllClipsScreen` does), derive the filter
        // actually applied from the current scope — this whole screen
        // already rebuilds off `widget.library`, so a kind that's lost its
        // last clip just quietly stops filtering next frame instead of
        // needing its own prune callback.
        final effectiveKind =
            (_filterKind != null && scoped.any((c) => c.event == _filterKind))
                ? _filterKind
                : null;
        final visible = effectiveKind == null
            ? scoped
            : scoped.where((c) => c.event == effectiveKind).toList();
        final clips = List.of(visible)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _header(context, entry),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: _integrationCard(context, entry),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: _captureSettingsCard(context, entry),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 4),
              child: Text('Clips', style: Theme.of(context).textTheme.title),
            ),
            EventFilterChips(
              clips: scoped,
              selected: effectiveKind,
              onSelected: (k) => setState(() => _filterKind = k),
            ),
            if (clips.isEmpty)
              _EmptyGameClips(
                  displayName: entry.displayName,
                  hotkeyLabel: widget.hotkeyLabel)
            else
              ListView.builder(
                key: const ValueKey('clipsList'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: clips.length,
                itemBuilder: (context, i) =>
                    ClipTile(clip: clips[i], library: widget.library),
              ),
          ],
        );
      },
    );
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
          // No fake stats: the fact row only appears once this game has a
          // clip (§3.4 — "omit facts when zero clips").
          if (entry.clipCount > 0) ...[
            const SizedBox(height: 8),
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

  Widget _integrationCard(BuildContext context, GameEntry entry) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return _Card(
      key: const ValueKey('integrationCard'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._integrationBody(context, entry),
          if (_isLeague && _liveEvents.isNotEmpty) ...[
            const SizedBox(height: 16),
            Column(
              key: const ValueKey('liveEventsSlot'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LIVE EVENTS',
                    style: theme.textTheme.micro
                        .copyWith(color: tokens.textMuted)),
                const SizedBox(height: 8),
                for (final e in _liveEvents) _LiveEventRow(event: e),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _integrationBody(BuildContext context, GameEntry entry) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;

    // League's merged row (§3.5 merge rule, extended to the hub): the vendor
    // Live Client API is the primary status; when the catalog's generic
    // process-detection also contributed to this row, note it as a second,
    // muted line rather than showing two competing "primary" statuses.
    if (entry.detection.contains(DetectionMethod.liveClientApi)) {
      final active = entry.active;
      return [
        Text('LIVE CLIENT API',
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
        const SizedBox(height: 8),
        _StatusRow(
          active: active,
          text: active
              ? 'In match — connected to 127.0.0.1:2999'
              : 'Waiting for a match. Detection is automatic — start a '
                  'game and Rewind connects.',
        ),
        if (entry.detection.contains(DetectionMethod.processWatch) &&
            entry.processMatch != null) ...[
          const SizedBox(height: 8),
          Text(
            'Also detected via process — watching for ${entry.processMatch} '
            'when the League client is open.',
            style: theme.textTheme.bodyMuted,
          ),
        ],
      ];
    }

    if (entry.detection.contains(DetectionMethod.processWatch)) {
      return [
        Text('PROCESS DETECTION',
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
        const SizedBox(height: 8),
        _StatusRow(
          active: entry.active,
          text: entry.active
              ? 'Running now'
              : 'Watching for ${entry.processMatch}',
        ),
        const SizedBox(height: 8),
        Text(
          'No event API for this game — clips are hotkey-only.',
          style: theme.textTheme.bodyMuted,
        ),
      ];
    }

    return [
      Text('MANUAL CAPTURE',
          style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
      const SizedBox(height: 8),
      Text(
        'Clips saved with ${widget.hotkeyLabel} while no game is detected.',
        style: theme.textTheme.body,
      ),
    ];
  }

  Widget _captureSettingsCard(BuildContext context, GameEntry entry) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CAPTURE SETTINGS',
              style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
          const SizedBox(height: 12),
          Text('Buffer length', style: theme.textTheme.body),
          const SizedBox(height: 8),
          SegmentedButton<String>(
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
          if (_customBuffer) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 160,
              child: TextField(
                key: const ValueKey('gameHubBufferField'),
                controller: _bufferController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Seconds (5-300)'),
                onChanged: _handleCustomBufferChanged,
              ),
            ),
          ],
          // Only League emits events (§3.4 — "the only source that emits
          // events"): catalog/desktop games get buffer-only settings, with
          // the event UI hidden entirely rather than shown-and-disabled.
          if (_isLeague) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: Text('Auto-clip', style: theme.textTheme.body)),
                Switch(
                  key: const ValueKey('gameHubAutoClipSwitch'),
                  value: _autoClip,
                  onChanged: _setAutoClip,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Opacity(
              opacity: _autoClip ? 1 : 0.4,
              child: IgnorePointer(
                ignoring: !_autoClip,
                child: Column(
                  key: const ValueKey('gameHubEventMatrix'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _eventGroup(context, 'COMBAT', _combatEvents),
                    const SizedBox(height: 12),
                    _eventGroup(context, 'OBJECTIVES', _objectiveEvents),
                    const SizedBox(height: 12),
                    _eventGroup(context, 'MATCH', _matchEvents),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _eventGroup(
      BuildContext context, String label, List<GameEventKind> kinds) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in kinds)
              _EventToggleChip(
                key: ValueKey('eventToggle:${kind.name}'),
                kind: kind,
                selected: _enabledEvents.contains(kind),
                onChanged: (value) => _toggleEvent(kind, value),
              ),
          ],
        ),
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

/// A dot + status line, shared by the League and process-watch integration
/// bodies — mint when [active], muted otherwise (no pulse: only the
/// recorder deck's REC dot earns motion, per §2).
class _StatusRow extends StatelessWidget {
  final bool active;
  final String text;

  const _StatusRow({required this.active, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final color = active ? tokens.accent : tokens.textMuted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: const SizedBox(width: 8, height: 8),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.body)),
      ],
    );
  }
}

/// One row in the v0.2 live-events feed slot: badge + relative age, styled
/// like `ClipTile`'s own event badge.
class _LiveEventRow extends StatelessWidget {
  final GameEvent event;

  const _LiveEventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          EventBadge(kind: event.kind),
          const SizedBox(width: 8),
          Text(relativeAge(event.time), style: theme.textTheme.bodyMuted),
        ],
      ),
    );
  }
}

/// A checkbox-styled chip for the auto-clip event matrix: accent fill/border
/// when enabled, hairline otherwise — same visual language as
/// `EventFilterChips`, but a boolean toggle rather than a single-select.
class _EventToggleChip extends StatelessWidget {
  final GameEventKind kind;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const _EventToggleChip({
    required this.kind,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final accent = tokens.accent;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onChanged(!selected),
        borderRadius: BorderRadius.circular(tokens.radiusChip),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : tokens.surface,
            borderRadius: BorderRadius.circular(tokens.radiusChip),
            border: Border.fromBorderSide(
                selected ? BorderSide(color: accent) : hairlineBorder()),
          ),
          child: Text(
            eventBadge(kind),
            style: theme.textTheme.label
                .copyWith(color: selected ? accent : tokens.text),
          ),
        ),
      ),
    );
  }
}

/// A hairline-bordered card — the hub's unit of structure (integration
/// status, capture settings), matching `_Section`'s treatment in the
/// (embedded) Settings destination.
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
