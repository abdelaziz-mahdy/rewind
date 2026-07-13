import 'package:flutter/material.dart';

import '../../clip/clip.dart';
import '../../events/game_catalog.dart';
import '../theme.dart';

/// Horizontal filter-chip rail for narrowing the library to one app/game.
/// "All" always leads, followed by one chip per distinct [Clip.gameId]
/// found in [clips] (alphabetical by prettified label), each carrying a
/// count badge. Filtering a single-game library has nothing to offer, so
/// this widget always renders its full contents — it's the caller's job
/// (see HomeScreen) to omit it entirely rather than mount a widget that
/// hides itself.
class GameFilterRail extends StatelessWidget {
  final List<Clip> clips;
  final String? selected;
  final ValueChanged<String?> onSelected;

  const GameFilterRail({
    required this.clips,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final clip in clips) {
      counts[clip.gameId] = (counts[clip.gameId] ?? 0) + 1;
    }

    final ids = counts.keys.toList()
      ..sort((a, b) => displayNameFor(a).compareTo(displayNameFor(b)));

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          _FilterChip(
            key: const ValueKey('gameFilterChip:all'),
            label: 'All',
            count: clips.length,
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          for (final id in ids) ...[
            const SizedBox(width: 8),
            _FilterChip(
              key: ValueKey('gameFilterChip:$id'),
              label: displayNameFor(id),
              count: counts[id]!,
              selected: selected == id,
              onTap: () => onSelected(id),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single pill in the rail: label + count badge, accent-highlighted when
/// selected. Visual language matches [hairlineBorder]-bordered surfaces
/// used throughout (see status_strip.dart's game chip).
class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.16)
                : theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(999),
            border: Border.fromBorderSide(
                selected ? BorderSide(color: accent) : hairlineBorder()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: selected ? accent : theme.colorScheme.onSurface,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.24)
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color:
                        selected ? accent : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
