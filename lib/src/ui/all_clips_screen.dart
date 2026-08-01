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
import 'widgets/session_card.dart';

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
///
/// Sentence case, not caps: this becomes a PAGE TITLE (the match screen's app
/// bar). All-caps is this design system's metadata voice — section labels, the
/// card's own context line — and a shouted title sat at odds with every other
/// header in the app ("All clips", "League of Legends", "Capture").
String _sessionLabel(ClipSession session, MatchStats? stats) {
  final word = stats != null ? 'Match' : 'Session';
  final count = session.clips.length;
  return '$word · ${relativeAge(session.startedAt)} · '
      '$count ${count == 1 ? 'clip' : 'clips'}';
}

/// How the session grid is ordered. Recency is the default and the only one
/// that matters most of the time; the other two exist because "which of
/// these is eating my disk" and "where is that long one" are real questions
/// a 3 GB library can't otherwise answer.
enum ClipSort { newest, largest, longest }

extension _SortLabel on ClipSort {
  String get label => switch (this) {
        ClipSort.newest => 'Newest',
        ClipSort.largest => 'Largest',
        ClipSort.longest => 'Most clips',
      };
}

/// The cross-game clip library: header (title + count + size + sort + open-
/// folder), an event-kind filter row, and a grid of SESSION CARDS —
/// interleaved across games by recency, not game-partitioned (the per-game
/// hubs already own that view).
///
/// The cards are the same `SessionCard` a game hub renders. This screen and
/// a hub show the same thing at the same level and differ only in scope, so
/// they must not disagree about what a session is or how it is summarized;
/// they used to use two different layouts and two different aspect ratios
/// for identical data, which meant nothing a user learned on one transferred
/// to the other. Tapping a card opens that session's clips, exactly as a hub
/// card does.
class AllClipsScreen extends StatefulWidget {
  final ClipLibrary library;
  final String hotkeyLabel;
  final VoidCallback onOpenClipsFolder;

  /// How far back a save reaches right now — shown by the first-run empty
  /// state, which teaches exactly that.
  final int bufferSeconds;

  /// Opens the Supported Games catalog. Null in tests that don't wire it,
  /// which simply drops the empty state's primary action.
  final VoidCallback? onAddGame;
  final ThumbnailCache? thumbnails;

  /// Per-match K/D and event history, keyed by (gameId, session start) — see
  /// [_statsForSession]. Null (every test that doesn't care) just means
  /// every session renders as a plain SESSION with no timeline markers.
  final MatchStatsStore? matchStats;

  /// Source of champion/item art for the match screen League opens into.
  /// Null always renders the monogram/blank art fallbacks — same as
  /// `GameHubScreen.ddragon`.
  final DDragon? ddragon;

  /// Real app icons by gameId (see `GameEntry.iconPath`), so a card in this
  /// cross-game grid shows the same icon the rail does for that game. Absent
  /// ids fall back to the monogram tile. Optional — a caller with no game
  /// directory in hand (every test that doesn't care) gets monograms.
  final Map<String, String> gameIconPaths;

  const AllClipsScreen({
    required this.library,
    required this.hotkeyLabel,
    required this.onOpenClipsFolder,
    this.bufferSeconds = 30,
    this.onAddGame,
    this.thumbnails,
    this.matchStats,
    this.ddragon,
    this.gameIconPaths = const {},
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

  ClipSort _sort = ClipSort.newest;

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
            bufferSeconds: widget.bufferSeconds,
            onAddGame: widget.onAddGame,
          );
        }

        final kind = _filterKind;
        final visible =
            kind == null ? scoped : scoped.where((c) => c.event == kind);
        final clips = List.of(visible)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final totalBytes = scoped.fold<int>(0, (sum, c) => sum + c.sizeBytes);
        final sessions = _sorted(_sessionFeed(clips));

        return ContentColumn(
            child: Column(
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
                      style: Theme.of(context)
                          .textTheme
                          .numeral
                          .copyWith(color: context.rewindTokens.textMuted),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _SortButton(
                    sort: _sort,
                    onChanged: (s) => setState(() => _sort = s),
                  ),
                  const SizedBox(width: 8),
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
              child: sessions.isEmpty
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
                            onPressed: () => setState(() => _filterKind = null),
                            child: const Text('Clear filter'),
                          ),
                        ],
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) => GridView.builder(
                        key: const ValueKey('clipsList'),
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent:
                              clipGridExtentFor(constraints.maxWidth),
                          mainAxisSpacing: clipGridSpacing,
                          crossAxisSpacing: clipGridSpacing,
                          childAspectRatio: sessionCardAspectRatio,
                        ),
                        itemCount: sessions.length,
                        itemBuilder: (context, i) {
                          final entry = sessions[i];
                          final stats = _statsForSession(
                              widget.matchStats, entry.session);
                          return SessionCard(
                            key: ValueKey('sessionCard:${entry.gameId}:'
                                '${entry.session.startedAt.toIso8601String()}'),
                            session: entry.session,
                            // Stats only ever get recorded by a vendor
                            // integration, so their presence is the honest
                            // proxy for MATCH vs SESSION here — All Clips has
                            // no GameEntry to ask.
                            isMatch: stats != null,
                            stats: stats,
                            thumbnails: widget.thumbnails,
                            ddragon: widget.ddragon,
                            gameId: entry.gameId,
                            displayName: entry.displayName,
                            iconPath: widget.gameIconPaths[entry.gameId],
                            onTap: () => _openMatch(context, entry, stats),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ));
      },
    );
  }

  List<_SessionEntry> _sorted(List<_SessionEntry> entries) {
    final out = List.of(entries);
    switch (_sort) {
      case ClipSort.newest:
        break; // _sessionFeed already returns newest-first
      case ClipSort.largest:
        out.sort((a, b) => _bytes(b).compareTo(_bytes(a)));
      case ClipSort.longest:
        out.sort(
            (a, b) => b.session.clips.length.compareTo(a.session.clips.length));
    }
    return out;
  }

  static int _bytes(_SessionEntry e) =>
      e.session.clips.fold<int>(0, (sum, c) => sum + c.sizeBytes);
}

/// The header's sort control. A bordered menu button rather than a row of
/// chips: sort is one choice out of three, and the event filter beneath it
/// already owns the chip vocabulary for multi-valued filtering.
class _SortButton extends StatelessWidget {
  final ClipSort sort;
  final ValueChanged<ClipSort> onChanged;

  const _SortButton({required this.sort, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final theme = Theme.of(context);
    return PopupMenuButton<ClipSort>(
      key: const ValueKey('sortButton'),
      tooltip: 'Sort sessions',
      padding: EdgeInsets.zero,
      initialValue: sort,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final s in ClipSort.values)
          PopupMenuItem(value: s, height: 36, child: Text(s.label)),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.fromBorderSide(hairlineBorder()),
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(sort.label,
                style: theme.textTheme.label.copyWith(color: tokens.textMuted)),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 16, color: tokens.textMuted),
          ],
        ),
      ),
    );
  }
}

/// First run. The one screen that has to teach Rewind's central idea.
///
/// It used to be a grey film glyph and "No clips yet — press Alt+F10 to save
/// your last moment", which never explains the thing everything else depends
/// on: Rewind is ALREADY recording, and the hotkey reaches BACKWARDS. So the
/// state shows the rolling window instead of describing it — a static bar
/// from -Ns to NOW, in the same `armed` amber the deck's tally is using at
/// that exact moment, so the two read as one signal.
///
/// Static by design: nothing in this app may animate while it sits in the
/// background (see `TransportDeck`'s ticker note).
class _EmptyLibrary extends StatelessWidget {
  final String hotkeyLabel;
  final VoidCallback onOpenClipsFolder;
  final int bufferSeconds;
  final VoidCallback? onAddGame;

  const _EmptyLibrary({
    required this.hotkeyLabel,
    required this.onOpenClipsFolder,
    this.bufferSeconds = 30,
    this.onAddGame,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    // Scrollable: with a permission banner above it on a short window there
    // is genuinely not enough room, and a first-run screen that overflows is
    // worse than one that scrolls.
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ARMED — RECORDING THE LAST $bufferSeconds SECONDS',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.micro.copyWith(color: tokens.armed),
                ),
                const SizedBox(height: 14),
                Text(
                  "Rewind is already rolling.\nYou don't press record — you press "
                  'rewind.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.display.copyWith(height: 1.25),
                ),
                const SizedBox(height: 22),
                _BufferDiagram(seconds: bufferSeconds),
                const SizedBox(height: 18),
                // Text.rich, not a Row: the keycap sits INSIDE the sentence, so
                // the line wraps like prose on a narrow window instead of
                // overflowing as a fixed-width run of three children.
                Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Hit '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: _KeyCap(label: hotkeyLabel),
                    ),
                    const TextSpan(text: ' after something good happens'),
                  ]),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMuted,
                ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (onAddGame != null) ...[
                      FilledButton(
                        key: const ValueKey('emptyAddGame'),
                        onPressed: onAddGame,
                        child: const Text('Add a game'),
                      ),
                    ],
                    OutlinedButton.icon(
                      onPressed: onOpenClipsFolder,
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                      label: const Text('Open clips folder'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The rolling window, drawn: a bar that fades in from -Ns and ends at a
/// hard NOW edge. The whole point is the direction — the saved clip is
/// BEHIND the playhead, not ahead of it.
class _BufferDiagram extends StatelessWidget {
  final int seconds;

  const _BufferDiagram({required this.seconds});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Semantics(
      label: 'Rewind continuously holds the last $seconds seconds; '
          'saving keeps that window',
      child: ExcludeSemantics(
        child: Column(
          children: [
            SizedBox(
              width: 300,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        gradient: LinearGradient(colors: [
                          tokens.armed.withValues(alpha: 0.10),
                          tokens.armed,
                        ]),
                      ),
                    ),
                  ),
                  Container(
                    width: 2,
                    height: 16,
                    decoration: BoxDecoration(
                      color: tokens.interactive,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 300,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('-$seconds s',
                      style: theme.textTheme.numeral
                          .copyWith(fontSize: 10, color: tokens.textDim)),
                  Text('NOW',
                      style: theme.textTheme.micro
                          .copyWith(fontSize: 9, color: tokens.textDim)),
                ],
              ),
            ),
          ],
        ),
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
      child: Text(label, style: theme.textTheme.numeral),
    );
  }
}
