import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../events/game_event.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';
import 'widgets/event_filter_chips.dart';

/// The cross-game clip library (§3.3): header (title + count + size + open-
/// folder), an event-kind filter row, and the clip list — newest first.
class AllClipsScreen extends StatefulWidget {
  final ClipLibrary library;
  final String hotkeyLabel;
  final VoidCallback onOpenClipsFolder;

  const AllClipsScreen({
    required this.library,
    required this.hotkeyLabel,
    required this.onOpenClipsFolder,
    super.key,
  });

  @override
  State<AllClipsScreen> createState() => _AllClipsScreenState();
}

class _AllClipsScreenState extends State<AllClipsScreen> {
  /// Selected event-kind filter; null means "All". Reset whenever its kind
  /// has no clips left in the library (e.g. the last clip of that kind was
  /// deleted).
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
  }

  @override
  void dispose() {
    widget.library.removeListener(_pruneFilterIfKindGone);
    super.dispose();
  }

  void _pruneFilterIfKindGone() {
    final kind = _filterKind;
    if (kind == null) return;
    final stillPresent = widget.library.all.any((c) => c.event == kind);
    if (!stillPresent && mounted) {
      setState(() => _filterKind = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        final scoped = widget.library.all;
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
                      'All clips',
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
            EventFilterChips(
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
