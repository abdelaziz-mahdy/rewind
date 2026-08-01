import 'package:flutter/material.dart';

import '../../clip/match_stats.dart';
import '../../clip/thumbnail_cache.dart';
import '../../games/league/ddragon.dart';
import '../../games/league/game_modes.dart';
import '../clip_sessions.dart';
import '../theme.dart';
import 'clip_tile.dart';
import 'dragon_art.dart';
import 'focus_ring.dart';
import 'game_tile_avatar.dart';

/// Match cards tile in the same column-count grid as clip tiles, but with a
/// taller footer (a label line plus a prominent K/D/A + CS readout), so they
/// get their own aspect ratio derived from that geometry — same width,
/// taller card.
const double _sessionFooterHeight = 76;
const double sessionCardAspectRatio = clipGridMaxCrossAxisExtent /
    (clipGridMaxCrossAxisExtent * 9 / 16 + _sessionFooterHeight);

const double _portraitSize = 28;

/// One card per play session, shared by BOTH the cross-game All Clips grid
/// and each game hub's grid — they show the same thing at the same level and
/// differ only in scope, so they must not disagree about what a session is
/// or how it is summarized. (Before this they used two different layouts and
/// two different aspect ratios for identical data.) All Clips passes
/// [displayName] so each card names its game; a hub omits it, since its whole
/// grid is already one game.
///
/// The card: a play session summarized. The thumbnail is the session's newest
/// clip, carrying only the champion portrait (when [ddragon] is wired up and
/// the match reports one — see [DDragon.championSquare]) plus the clip count
/// and any decided result. The match's KILLS / DEATHS / ASSISTS scoreboard
/// lives in the footer ONCE, with creep score — deliberately NOT an
/// event-type badge, which read as a misleading "1 kill" count, and no longer
/// duplicated over the thumbnail. Games/old matches with no recorded K/D fall
/// back to a clip count; no champion (or no [ddragon]) falls back to a
/// monogram, same as `GameTileAvatar`'s contract — never a broken image or a
/// hole. Tapping opens the session's clips (see [onTap]).
class SessionCard extends StatelessWidget {
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

  /// The game this session belongs to, for the footer's avatar + name. Null
  /// on a game hub, where every card is the same game and repeating its name
  /// on each one is noise.
  final String? gameId;
  final String? displayName;

  /// The game's real app icon (see `GameEntry.iconPath`), when one was ever
  /// captured. Null renders the monogram tile — the same contract
  /// `GameTileAvatar` has everywhere else.
  final String? iconPath;

  const SessionCard({
    required this.session,
    required this.isMatch,
    required this.stats,
    required this.onTap,
    this.thumbnails,
    this.ddragon,
    this.gameId,
    this.displayName,
    this.iconPath,
    super.key,
  });

  /// Whether there's a real K/D to show (recorded, non-empty).
  bool get _hasKd => stats != null && (stats!.kills > 0 || stats!.deaths > 0);

  /// Whether the match reported a champion — gates the portrait
  /// independently of [_hasKd] (a League match with no combat yet still has
  /// a champion).
  bool get _hasChampion =>
      stats?.champion != null && stats!.champion!.isNotEmpty;

  /// The muted top line MINUS its timestamp: "AHRI · ARENA", led by the game's
  /// own name on the cross-game grid, since that is what tells two cards apart
  /// there. The age is rendered separately (see [_ageLabel]) so it survives —
  /// this half is the part allowed to ellipsize.
  String _contextLabel() {
    final parts = <String>[];
    if (displayName case final n? when n.isNotEmpty) {
      parts.add(n.toUpperCase());
    }
    if (stats?.champion case final c? when c.isNotEmpty) {
      parts.add(c.toUpperCase());
    }
    // Resolved at render from the stored RAW code, never read straight out of
    // storage — see games/league/game_modes.dart for why.
    if (friendlyLeagueGameMode(stats?.gameMode) case final m?
        when m.isNotEmpty) {
      parts.add(m.toUpperCase());
    }
    // "MATCH"/"SESSION" stays only when there's nothing more specific to lead
    // with — a game name, or a champion + mode, already reads as one.
    if (parts.isEmpty) parts.add(isMatch ? 'MATCH' : 'SESSION');
    return parts.join(' · ');
  }

  String _ageLabel() => relativeAge(session.startedAt).toUpperCase();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final newest = session.clips.first; // clips are newest-first
    final count = session.clips.length;

    return FocusRing(
      radius: tokens.radiusCard,
      child: Material(
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
                        // K/D/A is NOT repeated here. It used to sit beside
                        // the portrait as "7/6/11" while the footer printed
                        // the same three numbers as "7 K 6 D 11 A" — two
                        // notations for one fact, on a card small enough that
                        // between them they took most of its ink. The footer
                        // copy wins: it sits on an opaque surface (this one
                        // needed a scrim to survive an arbitrary video frame),
                        // it labels what each number means, and it has room
                        // for creep score.
                        if (_hasChampion)
                          Positioned(
                            left: 8,
                            top: 8,
                            child: _ChampionPortrait(
                                ddragon: ddragon, stats: stats!),
                          ),
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // Count first, badge under it: the count is the
                              // one thing EVERY card has, so leading with it
                              // keeps it on the same line across a grid where
                              // only some matches have a decided result.
                              _CountPill(count: count),
                              if (stats?.result != null) ...[
                                const SizedBox(height: 6),
                                MatchResultBadge(result: stats!.result!),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: _sessionFooterHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (gameId case final id?) ...[
                                GameTileAvatar(
                                  gameId: id,
                                  displayName: displayName ?? id,
                                  iconPath: iconPath,
                                  size: 14,
                                ),
                                const SizedBox(width: 6),
                              ],
                              // The age is laid out AFTER the context and never
                              // shrinks: it is the grid's sort key, so a narrow
                              // card must drop the mode or the champion before
                              // it drops "2 H AGO". Ellipsizing one joined
                              // string truncated from the right and took the
                              // timestamp with it every time.
                              Flexible(
                                child: Text(
                                  _contextLabel(),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: theme.textTheme.micro
                                      .copyWith(color: tokens.textMuted),
                                ),
                              ),
                              Text(
                                ' · ${_ageLabel()}',
                                maxLines: 1,
                                style: theme.textTheme.micro
                                    .copyWith(color: tokens.textMuted),
                              ),
                            ],
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
    final champion = stats.champion!; // guarded by SessionCard._hasChampion
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
    final num = theme.textTheme.numeralLarge.copyWith(fontSize: 17);
    final label = theme.textTheme.micro.copyWith(color: tokens.textDim);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('${stats.kills}', style: num.copyWith(color: tokens.positive)),
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
              style: theme.textTheme.numeral
                  .copyWith(fontSize: 11, color: tokens.textDim)),
      ],
    );
  }
}

/// The "N clips" pill over the thumbnail's top-right, a dark scrim behind it
/// for legibility over any frame.
/// A WIN / LOSS chip for a decided match (see [MatchResult]). Green (accent)
/// for a win, red (rec) for a loss, over a dark scrim so it stays legible on
/// any thumbnail — the same treatment as the count pill it sits above.
/// Shared by the match card and the match screen.
class MatchResultBadge extends StatelessWidget {
  final MatchResult result;

  /// A larger variant for the match screen header (vs. the compact card pill).
  final bool large;

  const MatchResultBadge({required this.result, this.large = false, super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final theme = Theme.of(context);
    final isWin = result == MatchResult.win;
    final color = isWin ? tokens.positive : tokens.danger;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: large ? 10 : 8, vertical: large ? 4 : 3),
      decoration: BoxDecoration(
        // A DARK scrim under the tint, like the K/D badge beside it: this
        // chip sits on an arbitrary video frame, and a coloured label on a
        // low-alpha colour wash vanishes the moment that frame is bright.
        color: Color.alphaBlend(color.withValues(alpha: 0.22),
            Colors.black.withValues(alpha: 0.66)),
        borderRadius: BorderRadius.circular(tokens.radiusChip),
        border: Border.all(color: color),
      ),
      child: Text(
        isWin ? 'WIN' : 'LOSS',
        style: (large ? theme.textTheme.label : theme.textTheme.micro)
            .copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

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
              style: theme.textTheme.numeral
                  .copyWith(fontSize: 10.5, color: Colors.white)),
        ],
      ),
    );
  }
}
