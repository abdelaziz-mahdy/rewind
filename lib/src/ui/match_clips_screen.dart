import 'dart:io';

import 'package:flutter/material.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/duration_prober.dart';
import '../clip/match_export.dart';
import '../clip/match_stats.dart';
import '../clip/thumbnail_cache.dart';
import '../games/match_presentation.dart';
import 'clip_sessions.dart';
import 'match_timeline_screen.dart';
import 'theme.dart';
import 'clip_file_actions.dart';
import 'widgets/clip_tile.dart';
import 'widgets/session_card.dart' show MatchResultBadge;

/// Route name for the match drill-down, so navigation can be asserted in
/// widget tests without building the screen (which needs media_kit for its
/// [ClipTile] thumbnails, same pattern as `playerScreenRouteName`).
const String matchClipsScreenRouteName = 'matchClips';

/// The clips of ONE match (play session), reached by tapping a match card.
///
/// A generic session frame: app bar, then whatever an optional per-game
/// [MatchPresentation] renders above the clip grid (League: a compact
/// champion/K-D-A/items summary band, a footnote, a collapsed roster
/// disclosure — see `games/league/league_match_presentation.dart`). A
/// process-detected game with no presentation impl (`matchPresentationFor`
/// returns null) gets the bare frame — app bar + clip grid, nothing
/// invented — so this screen carries no per-game knowledge of its own.
class MatchClipsScreen extends StatelessWidget {
  final ClipSession session;
  final String matchLabel;
  final MatchStats? stats;
  final ClipLibrary library;
  final ThumbnailCache? thumbnails;

  /// Renders the game-specific summary band / footnote / extras above the
  /// clip grid. Null (no impl for this game, or a build/test that doesn't
  /// care) renders none of them.
  final MatchPresentation? presentation;

  /// "Export full match" — concatenates this match's clips into one
  /// shareable video. Null or unsupported hides the app-bar action.
  final MatchExporter? exporter;

  /// Duration probing for the "Watch match" timeline viewer (clip spans
  /// need real durations). Null hides that action.
  final DurationProber? prober;

  const MatchClipsScreen({
    required this.session,
    required this.matchLabel,
    required this.stats,
    required this.library,
    this.thumbnails,
    this.presentation,
    this.exporter,
    this.prober,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final s = stats;
    final summary = s != null ? presentation?.buildSummary(context, s) : null;
    final footnote = presentation?.footnote(s);
    final extras = s != null ? presentation?.buildExtras(context, s) : null;

    return Scaffold(
      appBar: AppBar(title: Text(matchLabel)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          // The match's headline actions live IN the content column, first
          // thing under the app bar — as app-bar icons they sat top-right,
          // outside where the eye actually lands on this screen
          // (maintainer: "far away from user vision").
          if ((prober != null && session.clips.isNotEmpty) ||
              (exporter != null && exporter!.isSupported))
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Row(
                children: [
                  if (stats?.result != null) ...[
                    MatchResultBadge(result: stats!.result!, large: true),
                    const SizedBox(width: 12),
                  ],
                  if (prober != null && session.clips.isNotEmpty)
                    FilledButton.icon(
                      key: const ValueKey('watchMatchButton'),
                      icon: const Icon(Icons.play_circle_outlined, size: 18),
                      label: const Text('Watch match'),
                      onPressed: () {
                        Navigator.of(context).push(MaterialPageRoute<void>(
                          settings: const RouteSettings(
                              name: matchTimelineScreenRouteName),
                          builder: (_) => MatchTimelineScreen(
                            session: session,
                            matchLabel: matchLabel,
                            stats: stats,
                            prober: prober!,
                          ),
                        ));
                      },
                    ),
                  const SizedBox(width: 12),
                  if (exporter != null && exporter!.isSupported)
                    _ExportMatchButton(
                        session: session,
                        library: library,
                        exporter: exporter!),
                ],
              ),
            ),
          if (summary != null)
            Padding(
              key: const ValueKey('matchSummary'),
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: summary,
            ),
          if (footnote != null)
            Padding(
              key: const ValueKey('matchFootnote'),
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                footnote,
                style: theme.textTheme.micro.copyWith(color: tokens.textMuted),
              ),
            ),
          if (extras != null)
            Padding(
              key: const ValueKey('matchExtras'),
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: extras,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            // Rebuilt from the LIBRARY, not the session snapshot this screen
            // was handed: exporting adds a clip to this very session, and
            // against a snapshot the new video simply never appeared —
            // the toast said "added to this match" over a grid that hadn't
            // changed. Trimming has the same shape.
            child: ListenableBuilder(
              listenable: library,
              builder: (context, _) {
                final clips = matchGridOrder(library.all, session);
                return GridView.builder(
                  key: const ValueKey('matchClipsList'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: clipGridMaxCrossAxisExtent,
                    mainAxisSpacing: clipGridSpacing,
                    crossAxisSpacing: clipGridSpacing,
                    childAspectRatio: clipGridChildAspectRatio,
                  ),
                  itemCount: clips.length,
                  itemBuilder: (context, i) => ClipTile(
                    clip: clips[i],
                    library: library,
                    thumbnails: thumbnails,
                    showGameName: false,
                    events: s?.events ?? const [],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The app-bar "Export full match" action: one continuous video from all
/// the match's clips (chronological, gaps between clips simply absent —
/// stream-copy concat, no re-encode), saved next to the clips with a
/// `-full-match` suffix. Owns its exporting flag so a long concat can't be
/// double-fired, and the success toast hands over the result (Reveal).
/// This match's clips in grid order: the whole-match video first, then the
/// individual clips newest-first.
///
/// The export leads because it is the one video that IS the session — it is
/// what someone opens the match to watch or share, and burying it in
/// timestamp order among forty near-identical thumbnails hides it exactly
/// when it is wanted. Trims stay in place: a trim is a moment, like the
/// clips around it.
///
/// Sourced from [all] rather than the session snapshot so a just-made export
/// or trim appears immediately.
List<Clip> matchGridOrder(List<Clip> all, ClipSession session) {
  // Start from the session as handed over — a caller that hasn't put these
  // clips in the library (tests, a preview) still gets its grid — then let
  // the library refresh what it knows and contribute anything NEW that
  // belongs to this session (an export or trim carries its sessionAt).
  final byPath = {for (final c in session.clips) c.path: c};
  for (final c in all) {
    if (byPath.containsKey(c.path) ||
        (c.sessionAt != null && c.sessionAt == session.startedAt)) {
      byPath[c.path] = c;
    }
  }
  final mine = byPath.values.toList();
  mine.sort((a, b) {
    final aExport = a.origin == ClipOrigin.exported;
    final bExport = b.origin == ClipOrigin.exported;
    if (aExport != bExport) return aExport ? -1 : 1;
    return b.createdAt.compareTo(a.createdAt);
  });
  return mine;
}

class _ExportMatchButton extends StatefulWidget {
  final ClipSession session;
  final ClipLibrary library;
  final MatchExporter exporter;

  const _ExportMatchButton({
    required this.session,
    required this.library,
    required this.exporter,
  });

  @override
  State<_ExportMatchButton> createState() => _ExportMatchButtonState();
}

class _ExportMatchButtonState extends State<_ExportMatchButton> {
  bool _exporting = false;

  Future<void> _export() async {
    // Chronological playback order — the grid shows newest first.
    //
    // CAPTURED clips only. An export is itself indexed into this session (so
    // it has a home, see below), and a previous export or trim is not source
    // footage: including them made each export swallow the last, turning
    // 43 MB of clips into a 258 MB export and then a 516 MB one.
    final ordered = widget.session.clips
        .where((c) => c.origin == ClipOrigin.captured)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (ordered.isEmpty) return;
    setState(() => _exporting = true);
    final outPath =
        matchExportPath(ordered.first, widget.library.all.map((c) => c.path));
    final ok = await widget.exporter.export(ordered, outPath);
    if (!mounted) return;
    setState(() => _exporting = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text("Couldn't export the match — clips may have been "
            'moved or deleted.'),
      ));
      return;
    }
    // The export joins the match it came from, exactly as a trim joins the
    // clip it came from (see PlayerScreen's trim: same gameId, same
    // sessionAt, an eventLabel naming what it is). A derived video is not a
    // loose file to go hunting for — it belongs to the session that produced
    // it, and lives in that session's grid where it can be played, revealed
    // and deleted like anything else.
    //
    // This is also what makes it survive: a button's "I just exported"
    // state dies with the screen, and the toast dies in six seconds.
    // Sync stat deliberately: an `await`ed dart:io call inside a widget's
    // callback never completes under a widget test's fake-async zone (see
    // CLAUDE.md's testing gotchas), and this one runs from a button press.
    // Indexed at size 0 rather than dropped if it can't be read — the
    // exporter said the file exists, and a transient stat failure must not
    // lose it.
    var size = 0;
    try {
      final file = File(outPath);
      if (file.existsSync()) size = file.lengthSync();
    } on FileSystemException {
      // Size stays 0.
    }
    widget.library.add(Clip(
      path: outPath,
      gameId: ordered.first.gameId,
      event: ordered.first.event,
      createdAt: ordered.first.createdAt,
      sizeBytes: size,
      sessionAt: ordered.first.sessionAt ?? widget.session.startedAt,
      origin: ClipOrigin.exported,
    ));
    await widget.library.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      content: const Text('Full match added to this match'),
      action: SnackBarAction(
        label: 'Reveal',
        onPressed: () async {
          final revealed = await revealClipFile(outPath);
          if (!revealed && mounted) showOpenFailedToast(context);
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: const ValueKey('exportMatchButton'),
      icon: _exporting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.movie_outlined, size: 18),
      label: Text(_exporting ? 'Exporting…' : 'Export as one video'),
      onPressed: _exporting ? null : _export,
    );
  }
}
