import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../clip/match_stats.dart';
import '../clip/thumbnail_cache.dart';
import '../games/match_presentation.dart';
import 'clip_sessions.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';

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

  const MatchClipsScreen({
    required this.session,
    required this.matchLabel,
    required this.stats,
    required this.library,
    this.thumbnails,
    this.presentation,
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
