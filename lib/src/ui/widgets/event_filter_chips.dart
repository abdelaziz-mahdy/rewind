import 'package:flutter/material.dart';

import '../../clip/clip.dart';
import '../../events/game_event.dart';
import '../theme.dart';
import 'clip_tile.dart' show eventBadge;

/// "All" + one chip per [GameEventKind] present in [clips], each with a
/// count. Shared by All Clips (cross-game event search) and the Game Hub
/// (scoped to that game's clips) — see docs/superpowers/specs/
/// 2026-07-13-game-centric-redesign.md §3.3/§3.4.
///
/// Omitted entirely (not just visually hidden) when it has nothing to offer:
/// fewer than two distinct kinds means "All" and the one other chip would
/// select the same clips.
class EventFilterChips extends StatelessWidget {
  final List<Clip> clips;
  final GameEventKind? selected;
  final ValueChanged<GameEventKind?> onSelected;

  const EventFilterChips({
    required this.clips,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final counts = <GameEventKind, int>{};
    for (final clip in clips) {
      counts[clip.event] = (counts[clip.event] ?? 0) + 1;
    }
    final kinds = counts.keys.toList()
      ..sort((a, b) => eventBadge(a).compareTo(eventBadge(b)));
    if (kinds.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
        children: [
          _Chip(
            key: const ValueKey('eventFilterChip:all'),
            label: 'All',
            count: clips.length,
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          for (final kind in kinds) ...[
            const SizedBox(width: 8),
            _Chip(
              key: ValueKey('eventFilterChip:${kind.name}'),
              label: eventBadge(kind),
              count: counts[kind]!,
              selected: selected == kind,
              onTap: () => onSelected(kind),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single rectangular chip: label + count badge, accent-highlighted when
/// selected.
class _Chip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
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
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusChip),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : tokens.surface,
            borderRadius: BorderRadius.circular(tokens.radiusChip),
            border: Border.fromBorderSide(
                selected ? BorderSide(color: accent) : hairlineBorder()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.label.copyWith(
                  color: selected ? accent : tokens.text,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.24)
                      : tokens.surfaceRaised,
                  borderRadius: BorderRadius.circular(tokens.radiusChip),
                ),
                child: Text(
                  '$count',
                  style: theme.textTheme.micro.copyWith(
                    color: selected ? accent : tokens.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
