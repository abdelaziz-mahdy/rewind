import 'package:flutter/material.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../events/game_catalog.dart';
import '../events/game_event.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';

/// The cross-game clip library (§3.3): header (title + count + size + open-
/// folder), an event-kind filter row, and the clip list — newest first.
///
/// Also doubles, until the real Game Hub (T4) lands, as the interim per-game
/// view: passing [gameId] scopes the header and list to that game (the
/// Shell's `GameDestination` route uses this rather than showing nothing).
class AllClipsScreen extends StatefulWidget {
  final ClipLibrary library;
  final String hotkeyLabel;
  final VoidCallback onOpenClipsFolder;

  /// When set, scopes the header/list to this gameId — the cheap interim
  /// game-hub view (see class doc). Null shows the full cross-game library.
  final String? gameId;

  const AllClipsScreen({
    required this.library,
    required this.hotkeyLabel,
    required this.onOpenClipsFolder,
    this.gameId,
    super.key,
  });

  @override
  State<AllClipsScreen> createState() => _AllClipsScreenState();
}

class _AllClipsScreenState extends State<AllClipsScreen> {
  /// Selected event-kind filter; null means "All". Reset whenever its kind
  /// has no clips left in the current scope (e.g. the last clip of that kind
  /// was deleted), mirroring the deleted per-game rail's same pruning rule.
  GameEventKind? _filterKind;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_pruneFilterIfKindGone);
  }

  @override
  void didUpdateWidget(covariant AllClipsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_pruneFilterIfKindGone);
      widget.library.addListener(_pruneFilterIfKindGone);
    }
    // Switching which game's clips this shows makes a stale kind filter from
    // the previous scope meaningless (or, worse, silently hides everything).
    if (oldWidget.gameId != widget.gameId) {
      _filterKind = null;
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_pruneFilterIfKindGone);
    super.dispose();
  }

  List<Clip> get _scoped {
    final all = widget.library.all;
    final gameId = widget.gameId;
    return gameId == null ? all : all.where((c) => c.gameId == gameId).toList();
  }

  void _pruneFilterIfKindGone() {
    final kind = _filterKind;
    if (kind == null) return;
    final stillPresent = _scoped.any((c) => c.event == kind);
    if (!stillPresent && mounted) {
      setState(() => _filterKind = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        final scoped = _scoped;
        if (scoped.isEmpty) {
          return _EmptyLibrary(
            hotkeyLabel: widget.hotkeyLabel,
            onOpenClipsFolder: widget.onOpenClipsFolder,
          );
        }

        final kind = _filterKind;
        final visible =
            kind == null ? scoped : scoped.where((c) => c.event == kind);
        final clips = List.of(visible)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final totalBytes = scoped.fold<int>(0, (sum, c) => sum + c.sizeBytes);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 4),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.gameId == null
                          ? 'All clips'
                          : displayNameFor(widget.gameId),
                      key: const ValueKey('allClipsTitle'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.display,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      '${scoped.length} clips · ${formatSize(totalBytes)}',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.bodyMuted,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Open clips folder',
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: widget.onOpenClipsFolder,
                  ),
                ],
              ),
            ),
            _EventFilterChips(
              clips: scoped,
              selected: _filterKind,
              onSelected: (k) => setState(() => _filterKind = k),
            ),
            Expanded(
              child: clips.isEmpty
                  ? _EmptyLibrary(
                      hotkeyLabel: widget.hotkeyLabel,
                      onOpenClipsFolder: widget.onOpenClipsFolder,
                    )
                  : ListView.builder(
                      key: const ValueKey('clipsList'),
                      itemCount: clips.length,
                      itemBuilder: (context, i) =>
                          ClipTile(clip: clips[i], library: widget.library),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// "All" + one chip per [GameEventKind] present in [clips], each with a
/// count — cross-game event search (§3.3). Mirrors the deleted per-game
/// rail's own rule: omitted entirely (not just visually hidden) when it has
/// nothing to offer — fewer than two distinct kinds means "All" and the one
/// other chip would select the same clips.
class _EventFilterChips extends StatelessWidget {
  final List<Clip> clips;
  final GameEventKind? selected;
  final ValueChanged<GameEventKind?> onSelected;

  const _EventFilterChips({
    required this.clips,
    required this.selected,
    required this.onSelected,
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
/// selected — same treatment as the deleted per-game rail's chip.
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

class _EmptyLibrary extends StatelessWidget {
  final String hotkeyLabel;
  final VoidCallback onOpenClipsFolder;

  const _EmptyLibrary({
    required this.hotkeyLabel,
    required this.onOpenClipsFolder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = context.rewindTokens.textMuted;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.movie_creation_outlined,
              size: 56, color: muted.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('No clips yet', style: theme.textTheme.title),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Press ',
                  style: theme.textTheme.body.copyWith(color: muted)),
              _KeyCap(label: hotkeyLabel),
              Text(' to save your last moment',
                  style: theme.textTheme.body.copyWith(color: muted)),
            ],
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onOpenClipsFolder,
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Open clips folder'),
          ),
        ],
      ),
    );
  }
}

/// A hotkey rendered as a physical keyboard key: bordered cap, tabular
/// figures for any digits. No drop shadow — the redesign carries the "raised
/// key" read via the border alone (see docs/superpowers/specs/
/// 2026-07-13-game-centric-redesign.md §2: "elevation/shadows ... none").
class _KeyCap extends StatelessWidget {
  final String label;

  const _KeyCap({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: context.rewindTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(context.rewindTokens.radiusControl),
        border: Border.all(color: context.rewindTokens.hairline),
      ),
      child: Text(
        label,
        style: theme.textTheme.label.copyWith(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
