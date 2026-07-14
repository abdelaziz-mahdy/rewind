import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../coordinator/clip_coordinator.dart';
import '../../clip/clip_library.dart';
import '../game_directory.dart';
import '../shell_destination.dart';
import '../theme.dart';
import 'game_tile_avatar.dart';

/// The persistent 220 px left rail (see docs/superpowers/specs/
/// 2026-07-13-game-centric-redesign.md §3.1): wordmark, All Clips, one row
/// per library game (live-rebuilt off [library], [ClipCoordinator.
/// activeGameIds], and [settingsRevision]), + Add game, then Settings/Logs.
class NavRail extends StatelessWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;

  /// See [ClipCoordinator]'s settings-mutated-in-place callers — bumped
  /// whenever a game gets configured (e.g. a per-game buffer edit), which the
  /// rail's game list must reflect even though `library`/`activeGameIds`
  /// didn't change. Optional so callers/tests that never touch settings
  /// don't need to wire it.
  final ValueListenable<int>? settingsRevision;

  final ShellDestination selected;
  final ValueChanged<ShellDestination> onSelect;
  final VoidCallback onOpenLogs;

  const NavRail({
    required this.coordinator,
    required this.library,
    this.settingsRevision,
    required this.selected,
    required this.onSelect,
    required this.onOpenLogs,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final revision = settingsRevision;
    final listenable = Listenable.merge([
      library,
      coordinator.activeGameIds,
      if (revision != null) revision,
    ]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) => _buildRail(context),
    );
  }

  Widget _buildRail(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final entries = buildGameDirectory(
      settings: coordinator.settings,
      clips: library.all,
      activeIds: coordinator.activeGameIds.value,
    );

    return Container(
      key: const ValueKey('navRail'),
      width: 220,
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(right: hairlineBorder()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
            child: Text(
              'REWIND',
              style: theme.textTheme.title.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
          ),
          _NavItem(
            key: const ValueKey('navItem:allClips'),
            icon: Icons.video_library_outlined,
            label: 'All Clips',
            selected: selected is AllClipsDestination,
            onTap: () => onSelect(const AllClipsDestination()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              'GAMES',
              style: theme.textTheme.micro.copyWith(color: tokens.textMuted),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final entry in entries)
                  _GameRow(
                    key: ValueKey('navGame:${entry.gameId}'),
                    entry: entry,
                    selected: selected is GameDestination &&
                        (selected as GameDestination).gameId == entry.gameId,
                    onTap: () => onSelect(GameDestination(entry.gameId)),
                  ),
              ],
            ),
          ),
          _NavItem(
            key: const ValueKey('navItem:addGame'),
            icon: Icons.add,
            label: '+ Add game',
            selected: selected is SupportedGamesDestination,
            onTap: () => onSelect(const SupportedGamesDestination()),
          ),
          Divider(height: 1, color: tokens.hairline),
          _NavItem(
            key: const ValueKey('navItem:settings'),
            icon: Icons.settings_outlined,
            label: 'Settings',
            selected: selected is SettingsDestination,
            onTap: () => onSelect(const SettingsDestination()),
          ),
          _NavItem(
            key: const ValueKey('navItem:logs'),
            icon: Icons.receipt_long_outlined,
            label: 'Logs',
            selected: false,
            onTap: onOpenLogs,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// One 48 px rail row shared by the fixed nav items (All Clips, + Add game,
/// Settings, Logs): icon + label, a 2 px accent left bar and raised-surface
/// fill when selected — no pill (§2 shape rules).
class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final color = selected ? tokens.accent : tokens.textMuted;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected ? tokens.surfaceRaised : null,
            border: Border(
              left: BorderSide(
                color: selected ? tokens.accent : Colors.transparent,
                width: tokens.radiusRailIndicator,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 12),
              Text(
                label,
                style: (selected ? theme.textTheme.title : theme.textTheme.body)
                    .copyWith(color: selected ? tokens.accent : tokens.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One rail row for a [GameEntry]: name, a live mint dot when [GameEntry.
/// active], and its clip count (tabular, muted) — see §3.1.
class _GameRow extends StatelessWidget {
  final GameEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _GameRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected ? tokens.surfaceRaised : null,
            border: Border(
              left: BorderSide(
                color: selected ? tokens.accent : Colors.transparent,
                width: tokens.radiusRailIndicator,
              ),
            ),
          ),
          child: Row(
            children: [
              GameTileAvatar(
                gameId: entry.gameId,
                displayName: entry.displayName,
                size: 28,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.displayName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: (selected
                          ? theme.textTheme.title
                          : theme.textTheme.body)
                      .copyWith(color: selected ? tokens.accent : tokens.text),
                ),
              ),
              if (entry.active) ...[
                DecoratedBox(
                  decoration: BoxDecoration(
                      color: tokens.accent, shape: BoxShape.circle),
                  child: const SizedBox(width: 6, height: 6),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                '${entry.clipCount}',
                style: theme.textTheme.label.copyWith(
                  color: tokens.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
