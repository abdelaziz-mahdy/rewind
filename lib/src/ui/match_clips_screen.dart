import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../clip/match_stats.dart';
import '../clip/thumbnail_cache.dart';
import 'clip_sessions.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';

/// Route name for the match drill-down, so navigation can be asserted in
/// widget tests without building the screen (which needs media_kit for its
/// [ClipTile] thumbnails, same pattern as `playerScreenRouteName`).
const String matchClipsScreenRouteName = 'matchClips';

/// The clips of ONE match (play session), reached by tapping a match card.
/// A plain scrollable grid of [ClipTile]s under a header naming the match
/// and its kills/deaths — the per-clip view a match card summarizes.
class MatchClipsScreen extends StatelessWidget {
  final ClipSession session;
  final String matchLabel;
  final MatchStats? stats;
  final ClipLibrary library;
  final ThumbnailCache? thumbnails;

  const MatchClipsScreen({
    required this.session,
    required this.matchLabel,
    required this.stats,
    required this.library,
    this.thumbnails,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final s = stats;
    return Scaffold(
      appBar: AppBar(title: Text(matchLabel)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (s != null && (s.kills > 0 || s.deaths > 0))
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Text(
                '${s.kills} kills · ${s.deaths} deaths · '
                '${session.clips.length} clips',
                style: theme.textTheme.bodyMuted,
              ),
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
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Kills counted from the live game, even for fights not clipped.',
              style: theme.textTheme.micro.copyWith(color: tokens.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
