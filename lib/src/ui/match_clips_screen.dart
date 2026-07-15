import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../clip/match_stats.dart';
import '../clip/thumbnail_cache.dart';
import 'clip_sessions.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';

/// The League match metadata card at the top of the drill-down: champion +
/// mode headline, then teammates' and enemies' champions.
class _MatchInfoCard extends StatelessWidget {
  final MatchStats stats;

  const _MatchInfoCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final headline = [
      if (stats.champion != null) stats.champion!,
      if (stats.gameMode != null) stats.gameMode!,
    ].join(' · ');

    Widget team(String label, List<String> champs, Color color) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in champs)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(tokens.radiusChip),
                      border: Border.all(color: color.withValues(alpha: 0.4)),
                    ),
                    child: Text(c,
                        style: theme.textTheme.micro.copyWith(color: color)),
                  ),
              ],
            ),
          ],
        );

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        border: Border.fromBorderSide(hairlineBorder()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (headline.isNotEmpty) Text(headline, style: theme.textTheme.title),
          // A real 2-team split (Summoner's Rift, ARAM) shows YOUR TEAM vs
          // ENEMIES. Arena and other multi-team modes have no reliable team
          // data (see LeagueEventWatcher), so allies is empty and every
          // other champion lands in one neutral list.
          if (stats.allies.isNotEmpty) ...[
            const SizedBox(height: 16),
            team('YOUR TEAM', stats.allies, tokens.accent),
            if (stats.enemies.isNotEmpty) ...[
              const SizedBox(height: 16),
              team('ENEMIES', stats.enemies, theme.colorScheme.error),
            ],
          ] else if (stats.enemies.isNotEmpty) ...[
            const SizedBox(height: 16),
            team('CHAMPIONS IN THIS GAME', stats.enemies, tokens.textMuted),
          ],
        ],
      ),
    );
  }
}

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
          if (s != null &&
              (s.champion != null ||
                  s.gameMode != null ||
                  s.allies.isNotEmpty ||
                  s.enemies.isNotEmpty))
            _MatchInfoCard(stats: s),
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
