import 'package:flutter/material.dart';

import '../../clip/match_stats.dart';
import '../../clip/thumbnail_cache.dart';
import '../../games/league/ddragon.dart';
import '../../games/league/game_modes.dart';
import '../clip_sessions.dart';
import '../theme.dart';
import 'clip_tile.dart';
import 'dragon_art.dart';
import 'game_tile_avatar.dart';

/// Match cards tile in the same column-count grid as clip tiles, but with a
/// taller footer (a label line plus a prominent K/D/A + CS readout), so they
/// get their own aspect ratio derived from that geometry — same width,
/// taller card.
const double _matchFooterHeight = 76;
const double matchCardAspectRatio = clipGridMaxCrossAxisExtent /
    (clipGridMaxCrossAxisExtent * 9 / 16 + _matchFooterHeight);

const double _portraitSize = 28;

/// One card in a game's match grid: a play session summarized. The
/// thumbnail is the session's newest clip, with the champion portrait (when
/// [ddragon] is wired up and the match reports one — see [DDragon.
/// championSquare]) and the match's KILLS / DEATHS / ASSISTS scoreboard (a
/// bold readout, shown both over the thumbnail and in the footer, plus creep
/// score in the footer) pinned over its top-left — deliberately NOT an
/// event-type badge, which read as a misleading "1 kill" count. Games/old
/// matches with no recorded K/D fall back to a clip count; no champion (or
/// no [ddragon]) falls back to a monogram, same as `GameTileAvatar`'s
/// contract — never a broken image or a hole. Tapping opens the session's
/// clips (see [onTap]).
class MatchCard extends StatelessWidget {
  final ClipSession session;

  /// Whether to head the card "MATCH" (games with an in-match API) vs
  /// "SESSION" (process-detected games, desktop).
  final bool isMatch;

  /// K/D for this session, or null when none was recorded.
  final MatchStats? stats;

  final ThumbnailCache? thumbnails;

  /// Source of champion/item art. Null (the default in every test that
  /// doesn't care about art, and any build before `main.dart` threads one
  /// through) always renders the monogram fallback.
  final DDragon? ddragon;

  final VoidCallback onTap;

  const MatchCard({
    required this.session,
    required this.isMatch,
    required this.stats,
    required this.onTap,
    this.thumbnails,
    this.ddragon,
    super.key,
  });

  /// Whether there's a real K/D to show (recorded, non-empty).
  bool get _hasKd => stats != null && (stats!.kills > 0 || stats!.deaths > 0);

  /// Whether the match reported a champion — gates the portrait
  /// independently of [_hasKd] (a League match with no combat yet still has
  /// a champion).
  bool get _hasChampion =>
      stats?.champion != null && stats!.champion!.isNotEmpty;

  /// The muted top line: "MATCH · 2 H AGO", enriched with the League match's
  /// champion and mode when captured — e.g. "AHRI · ARENA · 2 H AGO".
  String _labelLine() {
    final parts = <String>[];
    if (stats?.champion case final c? when c.isNotEmpty) {
      parts.add(c.toUpperCase());
    }
    // Resolved at render from the stored RAW code, never read straight out of
    // storage — see games/league/game_modes.dart for why.
    if (friendlyLeagueGameMode(stats?.gameMode) case final m?
        when m.isNotEmpty) {
      parts.add(m.toUpperCase());
    }
    parts.add(relativeAge(session.startedAt).toUpperCase());
    // "MATCH"/"SESSION" prefix stays only when there's no champion/mode to
    // lead with — champion + mode already reads as a match.
    if (parts.length == 1) parts.insert(0, isMatch ? 'MATCH' : 'SESSION');
    return parts.join(' · ');
  }

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
                      if (_hasChampion || _hasKd)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_hasChampion) ...[
                                _ChampionPortrait(
                                    ddragon: ddragon, stats: stats!),
                                const SizedBox(width: 6),
                              ],
                              if (_hasKd) _KdBadge(stats: stats!, large: true),
                            ],
                          ),
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
                          _labelLine(),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: theme.textTheme.micro
                              .copyWith(color: tokens.textMuted),
                        ),
                        const SizedBox(height: 8),
                        if (_hasKd)
                          _KdLine(stats: stats!)
                        else
                          Text(
                            '$count ${count == 1 ? 'clip' : 'clips'}',
                            style: theme.textTheme.body
                                .copyWith(color: tokens.textMuted),
                          ),
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

/// The champion portrait pinned at the thumbnail's top-left, ahead of the
/// K/D badge: real Data Dragon art when [ddragon] resolves one, else a
/// monogram tile keyed by the champion's name — reusing `GameTileAvatar`'s
/// own monogram primitives (`gameTileColor`/`gameTileInitials`) so an
/// unresolved champion reads with the same visual language as an unresolved
/// game icon elsewhere in the app, never a broken image or a hole.
class _ChampionPortrait extends StatelessWidget {
  final DDragon? ddragon;
  final MatchStats stats;

  const _ChampionPortrait({required this.ddragon, required this.stats});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final champion = stats.champion!; // guarded by MatchCard._hasChampion
    final placeholder = Container(
      alignment: Alignment.center,
      color: gameTileColor(champion),
      child: Text(
        gameTileInitials(champion),
        style: TextStyle(
          color: gameTileTextColor(champion),
          fontWeight: FontWeight.w800,
          fontSize: _portraitSize * 0.36,
          letterSpacing: -0.2,
          height: 1,
        ),
      ),
    );
    return Container(
      width: _portraitSize,
      height: _portraitSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(tokens.radiusChip),
        border: Border.all(color: Colors.black.withValues(alpha: 0.5)),
      ),
      child: DragonArt(
        future:
            ddragon?.championSquare(stats.championKey, championName: champion),
        size: _portraitSize,
        borderRadius: BorderRadius.circular(tokens.radiusChip),
        placeholder: placeholder,
      ),
    );
  }
}

/// The prominent footer scoreboard: big bold kills/deaths/assists numbers
/// with muted labels, plus creep score — the card's headline indicator.
class _KdLine extends StatelessWidget {
  final MatchStats stats;

  const _KdLine({required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final num = theme.textTheme.title.copyWith(fontWeight: FontWeight.w800);
    final label = theme.textTheme.body.copyWith(color: tokens.textMuted);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('${stats.kills}', style: num.copyWith(color: tokens.accent)),
        Text(' K', style: label),
        const SizedBox(width: 8),
        Text('${stats.deaths}',
            style: num.copyWith(color: theme.colorScheme.error)),
        Text(' D', style: label),
        const SizedBox(width: 8),
        Text('${stats.assists}', style: num.copyWith(color: tokens.text)),
        Text(' A', style: label),
        const Spacer(),
        if (stats.creepScore > 0)
          Text('${stats.creepScore} CS',
              style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
      ],
    );
  }
}

/// The K/D/A scoreboard chip over the thumbnail's top-left: a dark scrim so
/// it stays legible over any frame, kills tinted with the accent and deaths
/// with the error color. [large] bumps the type for the on-thumbnail copy.
class _KdBadge extends StatelessWidget {
  final MatchStats stats;
  final bool large;

  const _KdBadge({required this.stats, this.large = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final base = large ? theme.textTheme.body : theme.textTheme.micro;
    final numStyle = base.copyWith(fontWeight: FontWeight.w800);
    final slash = base.copyWith(color: Colors.white.withValues(alpha: 0.6));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(context.rewindTokens.radiusChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${stats.kills}',
              style: numStyle.copyWith(color: tokens.accent)),
          Text('/', style: slash),
          Text('${stats.deaths}',
              style: numStyle.copyWith(color: theme.colorScheme.error)),
          Text('/', style: slash),
          Text('${stats.assists}',
              style: numStyle.copyWith(color: Colors.white)),
        ],
      ),
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
        color: Colors.black.withValues(alpha: 0.6),
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
