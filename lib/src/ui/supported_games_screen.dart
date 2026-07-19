import 'package:flutter/material.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import '../events/game_catalog.dart';
import '../games/game_descriptor.dart';
import '../settings/app_settings.dart';
import 'theme.dart';
import 'widgets/game_tile_avatar.dart';

/// One row of the catalog: a display/detection label pair plus the set of
/// gameIds whose config/clips/activity count toward this row's state — for
/// the merged League row that's both its vendor id and the catalog's id.
class _CatalogRow {
  final String gameId;
  final String displayName;
  final String detectionLabel;
  final String? secondaryLabel;
  final Set<String> matchIds;

  const _CatalogRow({
    required this.gameId,
    required this.displayName,
    required this.detectionLabel,
    this.secondaryLabel,
    required this.matchIds,
  });
}

enum _RowState { running, inLibrary, addable }

/// The processMatch of the first non-primary id in [d]'s merged set that has
/// a [popularGamesCatalog] entry — e.g. League's "Also via process:
/// LeagueClientUx" secondary label. Null when there is none (no merged
/// descriptor lacks one today, but a future one might).
String? _secondaryLabelFor(GameDescriptor d) {
  for (final id in d.mergedGameIds) {
    if (id == d.primaryGameId) continue;
    final catalogMatch = popularGamesCatalog.where((g) => g.gameId == id);
    if (catalogMatch.isNotEmpty) {
      return 'Also via process: ${catalogMatch.first.processMatch}';
    }
  }
  return null;
}

List<_CatalogRow> _buildCatalogRows() {
  // A descriptor with more than one merged gameId (League: the vendor
  // integration + the catalog's generic `app:league_of_legends` entry) is
  // listed first and absorbs its catalog id, rather than showing a
  // confusing duplicate row (§3.5) — driven by the registry, not a
  // hardcoded League special case (Task 21).
  final mergedDescriptors =
      gameDescriptors.where((d) => d.mergedGameIds.length > 1);
  final absorbedCatalogIds = <String>{
    for (final d in mergedDescriptors)
      for (final id in d.mergedGameIds)
        if (id != d.primaryGameId) id,
  };
  return [
    for (final d in mergedDescriptors)
      _CatalogRow(
        gameId: d.primaryGameId,
        displayName: d.displayName,
        detectionLabel: d.hasLiveFeed ? 'Live Client API' : 'Process detection',
        secondaryLabel: _secondaryLabelFor(d),
        matchIds: d.mergedGameIds,
      ),
    for (final g in popularGamesCatalog)
      if (!absorbedCatalogIds.contains(g.gameId))
        _CatalogRow(
          gameId: g.gameId,
          displayName: g.displayName,
          detectionLabel: 'Process: ${g.processMatch}',
          matchIds: {g.gameId},
        ),
  ];
}

_RowState _stateFor(_CatalogRow row, AppSettings settings, List<Clip> clips,
    Set<String> activeIds) {
  if (row.matchIds.any(activeIds.contains)) return _RowState.running;
  final inLibrary =
      settings.allConfigs.any((c) => row.matchIds.contains(c.gameId)) ||
          clips.any((c) => row.matchIds.contains(c.gameId));
  return inLibrary ? _RowState.inLibrary : _RowState.addable;
}

/// The Supported Games catalog (§3.5): every title Rewind can auto-detect out
/// of the box, with League's vendor integration and its generic
/// process-detection catalog entry merged into one row. Each row shows a
/// derived state — a mint "Running" dot, a muted "In your library" label, or
/// an Add button — and Add writes through the same `settings.configFor` →
/// `setConfig` → `onSettingsChanged` path the hub's per-game settings use, so
/// the game appears in the rail immediately (the rail's directory rebuild is
/// already reactive to a settings mutation via `settingsRevision`).
class SupportedGamesScreen extends StatefulWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;

  /// Persists a settings change (mutated in place) — the Add flow's path.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Navigates the Shell to this game's hub — called when a running or
  /// in-library row is tapped. Addable rows aren't tappable to navigate;
  /// their explicit Add button is the only affordance.
  final ValueChanged<String> onOpenGame;

  const SupportedGamesScreen({
    required this.coordinator,
    required this.library,
    required this.onSettingsChanged,
    required this.onOpenGame,
    super.key,
  });

  @override
  State<SupportedGamesScreen> createState() => _SupportedGamesScreenState();
}

class _SupportedGamesScreenState extends State<SupportedGamesScreen> {
  void _addGame(String gameId) {
    final settings = widget.coordinator.settings;
    final cfg = settings.configFor(gameId);
    settings.setConfig(cfg);
    setState(() {});
    widget.onSettingsChanged(settings);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable:
          Listenable.merge([widget.library, widget.coordinator.activeGameIds]),
      builder: (context, _) {
        final settings = widget.coordinator.settings;
        final clips = widget.library.all;
        final activeIds = widget.coordinator.activeGameIds.value;
        final rows = _buildCatalogRows();

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Text('Supported Games', style: theme.textTheme.display),
            const SizedBox(height: 4),
            Text(
              'Games Rewind can auto-detect out of the box.',
              style: theme.textTheme.bodyMuted,
            ),
            const SizedBox(height: 16),
            for (final row in rows)
              _CatalogRowTile(
                key: ValueKey('supportedGameRow:${row.gameId}'),
                row: row,
                state: _stateFor(row, settings, clips, activeIds),
                onAdd: () => _addGame(row.gameId),
                onOpen: () => widget.onOpenGame(row.gameId),
              ),
            const SizedBox(height: 20),
            Text(
              'Rewind only reads official local APIs and process names — '
              'never game memory. Games without a sanctioned API get hotkey '
              'capture only.',
              style: theme.textTheme.bodyMuted,
            ),
          ],
        );
      },
    );
  }
}

/// One 56 px catalog row (§3.5): name + detection method on the left, the
/// derived state on the right. Tappable to open the hub once the game is
/// running or in the library; addable rows only respond to their Add button.
class _CatalogRowTile extends StatelessWidget {
  final _CatalogRow row;
  final _RowState state;
  final VoidCallback onAdd;
  final VoidCallback onOpen;

  const _CatalogRowTile({
    required this.row,
    required this.state,
    required this.onAdd,
    required this.onOpen,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final detail = row.secondaryLabel == null
        ? row.detectionLabel
        : '${row.detectionLabel} · ${row.secondaryLabel}';

    final content = Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.hairline)),
      ),
      child: Row(
        children: [
          GameTileAvatar(
            gameId: row.gameId,
            displayName: row.displayName,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.displayName, style: theme.textTheme.title),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodyMuted,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _StateIndicator(state: state, onAdd: onAdd),
        ],
      ),
    );

    if (state == _RowState.addable) return content;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onOpen, child: content),
    );
  }
}

/// The right-hand side of a catalog row: a live mint dot + "RUNNING", a muted
/// "IN YOUR LIBRARY" label, or an Add button — mirroring the rail's live dot
/// and the hub's status-pill treatment.
class _StateIndicator extends StatelessWidget {
  final _RowState state;
  final VoidCallback onAdd;

  const _StateIndicator({required this.state, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    switch (state) {
      case _RowState.running:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration:
                  BoxDecoration(color: tokens.accent, shape: BoxShape.circle),
              child: const SizedBox(width: 6, height: 6),
            ),
            const SizedBox(width: 6),
            Text('RUNNING',
                style: theme.textTheme.micro.copyWith(color: tokens.accent)),
          ],
        );
      case _RowState.inLibrary:
        return Text('IN YOUR LIBRARY',
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted));
      case _RowState.addable:
        return OutlinedButton(
          key: const ValueKey('addGameButton'),
          onPressed: onAdd,
          child: const Text('Add'),
        );
    }
  }
}
