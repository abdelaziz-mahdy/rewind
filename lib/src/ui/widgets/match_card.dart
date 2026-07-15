import 'package:flutter/material.dart';

import '../../clip/match_stats.dart';
import '../../clip/thumbnail_cache.dart';
import '../../events/game_event.dart';
import '../clip_sessions.dart';
import '../theme.dart';
import 'clip_tile.dart';

/// Match cards tile in the same column-count grid as clip tiles, but with a
/// taller footer (two info lines instead of one), so they get their own
/// aspect ratio derived from that geometry — same width, taller card.
const double _matchFooterHeight = 72;
const double matchCardAspectRatio = clipGridMaxCrossAxisExtent /
    (clipGridMaxCrossAxisExtent * 9 / 16 + _matchFooterHeight);

/// One card in a game's match grid: a play session summarized. The
/// thumbnail is the session's newest clip; overlays give the best moment's
/// event badge and the clip count; the footer gives the match label + age
/// and a kills/deaths summary (from [stats], when the game reports combat).
/// Tapping opens the session's clips (see [onTap]).
class MatchCard extends StatelessWidget {
  final ClipSession session;

  /// Whether to head the card "MATCH" (games with an in-match API) vs
  /// "SESSION" (process-detected games, desktop).
  final bool isMatch;

  /// K/D for this session, or null when none was recorded.
  final MatchStats? stats;

  final ThumbnailCache? thumbnails;
  final VoidCallback onTap;

  const MatchCard({
    required this.session,
    required this.isMatch,
    required this.stats,
    required this.onTap,
    this.thumbnails,
    super.key,
  });

  /// The session's most clip-worthy event — what the card badges.
  GameEventKind get _bestEvent => session.clips
      .map((c) => c.event)
      .reduce((a, b) => clipPriority(b) > clipPriority(a) ? b : a);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final newest = session.clips.first; // clips are newest-first
    final count = session.clips.length;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        child: Container(
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(tokens.radiusCard),
            border: Border.fromBorderSide(hairlineBorder()),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(tokens.radiusCard),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipThumbnail(clip: newest, thumbnails: thumbnails),
                      Positioned(
                        left: 8,
                        top: 8,
                        child: EventBadge(kind: _bestEvent),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: _CountPill(count: count),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: _matchFooterHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${isMatch ? 'MATCH' : 'SESSION'} · '
                          '${relativeAge(session.startedAt).toUpperCase()}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: theme.textTheme.micro
                              .copyWith(color: tokens.textMuted),
                        ),
                        const SizedBox(height: 6),
                        _SummaryLine(stats: stats, clipCount: count),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The card's second footer line: a K/D readout when [stats] exists
/// (kills tinted with the accent, deaths with the error color, like a
/// scoreboard), otherwise a plain clip count.
class _SummaryLine extends StatelessWidget {
  final MatchStats? stats;
  final int clipCount;

  const _SummaryLine({required this.stats, required this.clipCount});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final clipsText = '$clipCount ${clipCount == 1 ? 'clip' : 'clips'}';
    final s = stats;
    if (s == null || (s.kills == 0 && s.deaths == 0)) {
      return Text(clipsText,
          style: theme.textTheme.body.copyWith(color: tokens.textMuted));
    }
    return Row(
      children: [
        Text('${s.kills}',
            style: theme.textTheme.body
                .copyWith(color: tokens.accent, fontWeight: FontWeight.w700)),
        Text(' K',
            style: theme.textTheme.body.copyWith(color: tokens.textMuted)),
        const SizedBox(width: 8),
        Text('${s.deaths}',
            style: theme.textTheme.body.copyWith(
                color: theme.colorScheme.error, fontWeight: FontWeight.w700)),
        Text(' D',
            style: theme.textTheme.body.copyWith(color: tokens.textMuted)),
        const Spacer(),
        Text(clipsText,
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
      ],
    );
  }
}

/// The "N clips" pill over the thumbnail's top-right, a dark scrim behind it
/// for legibility over any frame.
class _CountPill extends StatelessWidget {
  final int count;

  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(context.rewindTokens.radiusChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.video_library_outlined,
              size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text('$count',
              style: theme.textTheme.micro.copyWith(color: Colors.white)),
        ],
      ),
    );
  }
}
