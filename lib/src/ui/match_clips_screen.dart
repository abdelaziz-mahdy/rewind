import 'package:flutter/material.dart';

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
import 'widgets/match_card.dart' show MatchResultBadge;

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
                      icon: const Icon(Icons.play_circle_outline, size: 18),
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
            child: GridView.builder(
              key: const ValueKey('matchClipsList'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: clipGridMaxCrossAxisExtent,
                mainAxisSpacing: clipGridSpacing,
                crossAxisSpacing: clipGridSpacing,
                childAspectRatio: clipGridChildAspectRatio,
              ),
              itemCount: session.clips.length,
              itemBuilder: (context, i) => ClipTile(
                clip: session.clips[i],
                library: library,
                thumbnails: thumbnails,
                showGameName: false,
                events: s?.events ?? const [],
              ),
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
    final ordered = List.of(widget.session.clips)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (ordered.isEmpty) return;
    setState(() => _exporting = true);
    final outPath = matchExportPath(
        ordered.first, widget.library.all.map((c) => c.path));
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      content: const Text('Full match exported'),
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
