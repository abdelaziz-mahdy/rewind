import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../coordinator/clip_coordinator.dart';
import '../../clip/clip_library.dart';
import '../game_directory.dart';
import '../shell_destination.dart';
import '../theme.dart';
import 'focus_ring.dart';
import 'game_tile_avatar.dart';

/// The persistent 220 px left rail: wordmark, All Clips, one row per library
/// game (live-rebuilt off [library], [ClipCoordinator.activeGameIds], and
/// [settingsRevision]), + Add game, then Settings/Logs.
///
/// NAVIGATION ONLY. The recorder controls that used to be pinned to its
/// bottom (`RecorderCluster`) now live in `TransportDeck`, above both the
/// rail and the content — see docs/superpowers/specs/
/// 2026-07-25-broadcast-deck-design-system.md §2. Keeping them here buried
/// the app's most important state in a sidebar and, worse, lost it entirely
/// on the Settings destination, which `Shell` renders without a rail.
/// Rail width when the window has room for labels, and when it doesn't.
const double navRailWidth = 220;
const double navRailCompactWidth = 64;

/// Below this window width the rail collapses to icons. A 220px rail is 27%
/// of an 820px window — this app lives BESIDE a game, so a half-screen
/// window is a normal way to use it, not an edge case.
const double navRailCompactBelow = 1000;

class NavRail extends StatelessWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;

  /// Icons only, no labels — see [navRailCompactBelow].
  final bool compact;

  /// The recorder chip, pinned under the wordmark (see `RecorderButton`).
  /// Built by `Shell` rather than here so the Settings destination — which
  /// has its own sidebar and no rail — can be handed the same widget.
  final Widget? recorder;

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
    this.compact = false,
    this.recorder,
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
      width: compact ? navRailCompactWidth : navRailWidth,
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(right: hairlineBorder()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 0 : 16, 20, 0, 20),
            child: Text(
              // The wordmark keeps its first letter as a mark when collapsed
              // rather than disappearing — the rail should still say whose
              // app it is.
              compact ? 'R' : 'REWIND',
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: theme.textTheme.title.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: compact ? 0 : 2,
              ),
            ),
          ),
          if (recorder case final r?) r,
          _NavItem(
            key: const ValueKey('navItem:allClips'),
            icon: Icons.video_library_outlined,
            label: 'All Clips',
            compact: compact,
            selected: selected is AllClipsDestination,
            onTap: () => onSelect(const AllClipsDestination()),
          ),
          if (compact)
            // A hairline stands in for the section label there is no room
            // to print — the grouping survives, the word doesn't.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Divider(height: 1, color: tokens.hairline),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                'GAMES',
                style: theme.textTheme.micro.copyWith(color: tokens.textDim),
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
                    compact: compact,
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
            label: 'Add game',
            compact: compact,
            selected: selected is SupportedGamesDestination,
            onTap: () => onSelect(const SupportedGamesDestination()),
          ),
          Divider(height: 1, color: tokens.hairline),
          _NavItem(
            key: const ValueKey('navItem:settings'),
            icon: Icons.settings_outlined,
            label: 'Settings',
            compact: compact,
            selected: selected is SettingsDestination,
            onTap: () => onSelect(const SettingsDestination()),
          ),
          _NavItem(
            key: const ValueKey('navItem:logs'),
            icon: Icons.receipt_long_outlined,
            label: 'Logs',
            compact: compact,
            selected: false,
            onTap: onOpenLogs,
          ),
        ],
      ),
    );
  }
}

/// One 48 px rail row shared by the fixed nav items (All Clips, + Add game,
/// Settings, Logs): icon + label, a 2 px interactive left bar and raised-surface
/// fill when selected — no pill (§2 shape rules).
class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final color = selected ? tokens.interactive : tokens.textMuted;
    return Tooltip(
      // The label has to survive collapsing — an icon-only rail with no
      // tooltip is a guessing game.
      message: compact ? label : '',
      waitDuration: const Duration(milliseconds: 400),
      child: FocusRing(
        radius: 0,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 48,
              padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 16),
              decoration: BoxDecoration(
                color: selected ? tokens.surfaceRaised : null,
                border: Border(
                  left: BorderSide(
                    color: selected ? tokens.interactive : Colors.transparent,
                    width: tokens.radiusRailIndicator,
                  ),
                ),
              ),
              child: compact
                  ? Center(child: Icon(icon, size: 18, color: color))
                  : Row(
                      children: [
                        Icon(icon, size: 18, color: color),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            label,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: (selected
                                    ? theme.textTheme.title
                                    : theme.textTheme.body)
                                .copyWith(
                                    color: selected
                                        ? tokens.interactive
                                        : tokens.text),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One rail row for a [GameEntry]: name, an [RewindTokens.armed] dot when
/// [GameEntry.active], and its clip count (numeral, muted).
class _GameRow extends StatelessWidget {
  final GameEntry entry;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _GameRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    // The full name in a tooltip — rail width truncates long titles
    // ("PenguinHotel-Win64-Shipping"), and hover should still reveal them.
    // When collapsed the tooltip is the ONLY way to read the name.
    return Tooltip(
      message: entry.displayName,
      waitDuration: const Duration(milliseconds: 500),
      child: FocusRing(
        radius: 0,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 48,
              // Tighter than the header padding to give long names more room.
              padding: EdgeInsets.only(
                  left: compact ? 0 : 12, right: compact ? 0 : 12),
              decoration: BoxDecoration(
                color: selected ? tokens.surfaceRaised : null,
                border: Border(
                  left: BorderSide(
                    color: selected ? tokens.interactive : Colors.transparent,
                    width: tokens.radiusRailIndicator,
                  ),
                ),
              ),
              child: compact
                  // Collapsed: the avatar alone, with the live dot tucked onto
                  // its corner so "this game is running" survives the collapse
                  // — it is the one piece of state the rail carries.
                  ? Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          GameTileAvatar(
                            gameId: entry.gameId,
                            displayName: entry.displayName,
                            iconPath: entry.iconPath,
                            size: 26,
                          ),
                          if (entry.active)
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Semantics(
                                label: '${entry.displayName} is running',
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: tokens.armed,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: tokens.surface, width: 1.5),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    )
                  : Row(
                      children: [
                        GameTileAvatar(
                          gameId: entry.gameId,
                          displayName: entry.displayName,
                          iconPath: entry.iconPath,
                          size: 26,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.displayName,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            // Selected reads prominent via color + weight, NOT a
                            // larger font — a bigger font just truncated sooner.
                            style: theme.textTheme.body.copyWith(
                              color:
                                  selected ? tokens.interactive : tokens.text,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (entry.active) ...[
                          const SizedBox(width: 6),
                          // `armed`, not the selection color: this dot reports
                          // that the GAME is running, which is machine state —
                          // the row's own highlight already says where you are.
                          Semantics(
                            label: '${entry.displayName} is running',
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                  color: tokens.armed, shape: BoxShape.circle),
                              child: const SizedBox(width: 6, height: 6),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Semantics(
                          label: '${entry.clipCount} '
                              '${entry.clipCount == 1 ? 'clip' : 'clips'}',
                          child: ExcludeSemantics(
                            child: Text(
                              '${entry.clipCount}',
                              style: theme.textTheme.numeral.copyWith(
                                fontSize: 12,
                                color: tokens.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
