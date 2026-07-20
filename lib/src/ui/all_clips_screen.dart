import 'package:flutter/material.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/duration_prober.dart';
import '../clip/match_export.dart';
import '../clip/match_stats.dart';
import '../clip/thumbnail_cache.dart';
import '../events/game_catalog.dart';
import '../events/game_event.dart';
import '../games/league/ddragon.dart';
import '../games/match_presentation.dart';
import 'clip_sessions.dart';
import 'match_clips_screen.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';
import 'widgets/event_filter_chips.dart';
import 'widgets/game_tile_avatar.dart';

/// One session in the All Clips feed, tagged with the display-name bucket it
/// came from (see [_sessionFeed]).
class _SessionEntry {
  final String gameId;
  final String displayName;
  final ClipSession session;
  const _SessionEntry({
    required this.gameId,
    required this.displayName,
    required this.session,
  });
}

/// Buckets [clips] (already sorted newest-first) by DISPLAY name — the same
/// League two-gameId merge `_groupByGame` used to apply (vendor id +
/// catalog process entry share one bucket, exactly like the rail/hubs) — runs
/// [groupClipsIntoSessions] per bucket, then flattens every bucket's
/// sessions into ONE newest-first feed across games. Unlike the old
/// per-game sectioning, sessions from different games interleave by
/// recency; only within a single game's own clips does anything get
/// game-partitioned first.
///
/// A session's representative [_SessionEntry.gameId] is its newest clip's —
/// arbitrary between a merged League session's two ids (either clip could
/// be newest), but only ever used for the header's icon and to seed
/// [_statsForSession]/`matchPresentationFor`, where either id is equally
/// correct.
List<_SessionEntry> _sessionFeed(List<Clip> clips) {
  final byName = <String, List<Clip>>{};
  for (final c in clips) {
    (byName[displayNameFor(c.gameId)] ??= []).add(c);
  }
  final entries = <_SessionEntry>[
    for (final bucket in byName.entries)
      for (final session in groupClipsIntoSessions(bucket.value))
        _SessionEntry(
          gameId: session.clips.first.gameId,
          displayName: bucket.key,
          session: session,
        ),
  ];
  entries.sort((a, b) => b.session.startedAt.compareTo(a.session.startedAt));
  return entries;
}

/// Stats are keyed by the SAVING gameId; a merged League session's clips may
/// carry either of its two gameIds (see `game_hub_screen.dart`'s identical
/// merge note). Tries every distinct gameId actually present in the
/// session's clips, in encounter order; the first non-null hit wins.
MatchStats? _statsForSession(MatchStatsStore? store, ClipSession session) {
  if (store == null) return null;
  for (final gameId in {for (final c in session.clips) c.gameId}) {
    final stats = store.statsFor(gameId, session.startedAt);
    if (stats != null) return stats;
  }
  return null;
}

/// Mirrors `GameHubScreen._sessionLabel`. All Clips has no [GameEntry] to
/// ask "does this game have a live-match API" — stats only ever get
/// recorded by League's vendor integration, so their presence is the honest
/// proxy for MATCH vs. SESSION here.
String _sessionLabel(ClipSession session, MatchStats? stats) {
  final word = stats != null ? 'MATCH' : 'SESSION';
  final count = session.clips.length;
  return '$word · ${relativeAge(session.startedAt).toUpperCase()} · '
      '$count ${count == 1 ? 'CLIP' : 'CLIPS'}';
}

/// The cross-game clip library (§3.3): header (title + count + size + open-
/// folder), an event-kind filter row, and a newest-first FEED OF SESSIONS —
/// each play session/match gets a tappable header (game + relative time +
/// clip count) and its own clip grid beneath, interleaved across games by
/// recency (not game-partitioned — the per-game hubs already own that view).
class AllClipsScreen extends StatefulWidget {
  final ClipLibrary library;
  final String hotkeyLabel;
  final VoidCallback onOpenClipsFolder;
  final ThumbnailCache? thumbnails;

  /// Per-match K/D and event history, keyed by (gameId, session start) — see
  /// [_statsForSession]. Null (every test that doesn't care) just means
  /// every session renders as a plain SESSION with no timeline markers.
  final MatchStatsStore? matchStats;

  /// Source of champion/item art for the match screen League opens into.
  /// Null always renders the monogram/blank art fallbacks — same as
  /// `GameHubScreen.ddragon`.
  final DDragon? ddragon;

  const AllClipsScreen({
    required this.library,
    required this.hotkeyLabel,
    required this.onOpenClipsFolder,
    this.thumbnails,
    this.matchStats,
    this.ddragon,
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

  void _openMatch(
      BuildContext context, _SessionEntry entry, MatchStats? stats) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: matchClipsScreenRouteName),
      builder: (_) => MatchClipsScreen(
        exporter: FfmpegMatchExporter(),
        prober: FfprobeDurationProber(),
        session: entry.session,
        matchLabel: _sessionLabel(entry.session, stats),
        stats: stats,
        library: widget.library,
        thumbnails: widget.thumbnails,
        presentation:
            matchPresentationFor(entry.gameId, ddragon: widget.ddragon),
      ),
    ));
  }

  /// The header + clip grid for one [_SessionEntry] — stats are looked up
  /// once here and threaded to both the header's tap (for the match label)
  /// and every [ClipTile] (for timeline markers), so a clip opened from All
  /// Clips finally carries the same markers it would from its game hub.
  List<Widget> _sessionSection(BuildContext context, _SessionEntry entry) {
    final stats = _statsForSession(widget.matchStats, entry.session);
    return [
      _SessionHeader(
        key: ValueKey(
            'sessionHeader:${entry.gameId}:${entry.session.startedAt.toIso8601String()}'),
        gameId: entry.gameId,
        displayName: entry.displayName,
        session: entry.session,
        onTap: () => _openMatch(context, entry, stats),
      ),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: clipGridMaxCrossAxisExtent,
          mainAxisSpacing: clipGridSpacing,
          crossAxisSpacing: clipGridSpacing,
          childAspectRatio: clipGridChildAspectRatio,
        ),
        itemCount: entry.session.clips.length,
        itemBuilder: (context, i) => ClipTile(
          clip: entry.session.clips[i],
          library: widget.library,
          thumbnails: widget.thumbnails,
          // The section header already names the game.
          showGameName: false,
          events: stats?.events ?? const [],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.matchStats == null
          ? widget.library
          : Listenable.merge([widget.library, widget.matchStats!]),
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
                  // One flexible child only (the subtitle, tight fill): with
                  // several loose flex-1 children sharing the row, each is
                  // ALLOCATED an equal slice of the free space whether it
                  // uses it or not — which stranded the folder button at
                  // ~60% width instead of flush right.
                  Text(
                    'All clips',
                    key: const ValueKey('allClipsTitle'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.display,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${scoped.length} clips · ${formatSize(totalBytes)}',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.bodyMuted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _FolderButton(onPressed: widget.onOpenClipsFolder),
                ],
              ),
            ),
            EventFilterChips(
              clips: scoped,
              selected: _filterKind,
              onSelected: (k) => setState(() => _filterKind = k),
            ),
            Expanded(
              // Clips exist but the active event filter matches none of
              // them — that's "nothing matches", not "library empty", so
              // the first-run guidance ("press the hotkey…") would be
              // wrong and the fix is one click away: clear the filter.
              child: clips.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'No clips match this filter',
                            style: Theme.of(context).textTheme.bodyMuted,
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            key: const ValueKey('clearFilterButton'),
                            onPressed: () =>
                                setState(() => _filterKind = null),
                            child: const Text('Clear filter'),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      key: const ValueKey('clipsList'),
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        for (final entry in _sessionFeed(clips))
                          ..._sessionSection(context, entry),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// A session's header row in the feed: avatar + display name + relative
/// time + clip count, tappable (chevron affordance) to open the full
/// [MatchClipsScreen] for that session — mirrors `GameHubScreen`'s match
/// card tap, just reached from a cross-game feed instead of a per-game grid.
class _SessionHeader extends StatelessWidget {
  final String gameId;
  final String displayName;
  final ClipSession session;
  final VoidCallback onTap;

  const _SessionHeader({
    required this.gameId,
    required this.displayName,
    required this.session,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final mutedStyle =
        Theme.of(context).textTheme.micro.copyWith(color: tokens.textMuted);
    final count = session.clips.length;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusControl),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Row(
            children: [
              GameTileAvatar(
                gameId: gameId,
                displayName: displayName,
                size: 20,
              ),
              const SizedBox(width: 8),
              // One Expanded filler only (the name/age/count run) — a
              // second loose flex widget sharing this row with it would hit
              // the flex-allocation trap the redesign spec calls out.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        displayName.toUpperCase(),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: mutedStyle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('·', style: mutedStyle),
                    const SizedBox(width: 8),
                    Text(relativeAge(session.startedAt), style: mutedStyle),
                    const SizedBox(width: 8),
                    Text(
                      '· $count ${count == 1 ? 'clip' : 'clips'}',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: mutedStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 16, color: tokens.textMuted),
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

/// The header's "open clips folder" affordance: a compact, hairline-bordered
/// square icon button flush with the header's right padding edge — a small
/// bordered control rather than a bare [IconButton] so it reads as a
/// deliberate action next to the title, not a stray floating glyph.
class _FolderButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _FolderButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    return IconButton(
      tooltip: 'Open clips folder',
      icon: const Icon(Icons.folder_open_outlined, size: 18),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        side: BorderSide(color: tokens.hairline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
        minimumSize: const Size(36, 36),
        visualDensity: VisualDensity.compact,
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
