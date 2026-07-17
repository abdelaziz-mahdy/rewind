import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../clip/match_stats.dart';
import '../clip/thumbnail_cache.dart';
import '../games/league/ddragon.dart';
import 'clip_sessions.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';
import 'widgets/dragon_art.dart';
import 'widgets/game_tile_avatar.dart';

const double _detailPortraitSize = 56;
const double _itemIconSize = 32;

/// The League match metadata card at the top of the drill-down: champion
/// portrait + skin + mode headline, the full stat line (K/D/A, CS, ward
/// score), the final item build, then teammates' and enemies' champions
/// (each with their in-game name, when known).
class _MatchInfoCard extends StatelessWidget {
  final MatchStats stats;
  final DDragon? ddragon;

  const _MatchInfoCard({required this.stats, required this.ddragon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final champion = stats.champion;
    final headline = [
      if (champion != null) champion,
      if (stats.gameMode != null) stats.gameMode!,
    ].join(' · ');

    Widget team(String label, List<MatchPlayer> players, Color color) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in players)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(tokens.radiusChip),
                      border: Border.all(color: color.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      // "Ahri" alone when the name isn't known (older
                      // matches, or an unresolved player), else
                      // "Ahri · PlayerName".
                      p.riotId == null || p.riotId!.isEmpty
                          ? p.championName
                          : '${p.championName} · ${p.riotId}',
                      style: theme.textTheme.micro.copyWith(color: color),
                    ),
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
          if (headline.isNotEmpty || champion != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (champion != null) ...[
                  _ChampionPortraitLarge(ddragon: ddragon, stats: stats),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (headline.isNotEmpty)
                        Text(headline, style: theme.textTheme.title),
                      if (stats.skinName case final skin? when skin.isNotEmpty)
                        Text(skin,
                            style: theme.textTheme.micro
                                .copyWith(color: tokens.textMuted)),
                    ],
                  ),
                ),
              ],
            ),
          if (_hasStatLine)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_statLine, style: theme.textTheme.bodyMuted),
            ),
          if (stats.items.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ItemBuild(ddragon: ddragon, items: stats.items),
          ],
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

  bool get _hasStatLine =>
      stats.kills > 0 ||
      stats.deaths > 0 ||
      stats.assists > 0 ||
      stats.creepScore > 0 ||
      stats.wardScore > 0;

  /// "12 K · 3 D · 7 A · 120 CS · 14.5 WS" — only the pieces that are
  /// actually non-zero, so an early-game match doesn't read "0 K · 0 D ·
  /// ...".
  String get _statLine {
    final parts = <String>[];
    if (stats.kills > 0 || stats.deaths > 0 || stats.assists > 0) {
      parts.add('${stats.kills} K');
      parts.add('${stats.deaths} D');
      parts.add('${stats.assists} A');
    }
    if (stats.creepScore > 0) parts.add('${stats.creepScore} CS');
    if (stats.wardScore > 0) {
      parts.add('${stats.wardScore.toStringAsFixed(1)} WS');
    }
    return parts.join(' · ');
  }
}

/// The large champion portrait in the match-info header, real Data Dragon
/// art when [ddragon] resolves one, else a monogram — same fallback
/// contract as `GameTileAvatar`/the match card's smaller portrait.
class _ChampionPortraitLarge extends StatelessWidget {
  final DDragon? ddragon;
  final MatchStats stats;

  const _ChampionPortraitLarge({required this.ddragon, required this.stats});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final champion = stats.champion!;
    final placeholder = Container(
      alignment: Alignment.center,
      color: gameTileColor(champion),
      child: Text(
        gameTileInitials(champion),
        style: TextStyle(
          color: gameTileTextColor(champion),
          fontWeight: FontWeight.w800,
          fontSize: _detailPortraitSize * 0.36,
          letterSpacing: -0.2,
          height: 1,
        ),
      ),
    );
    return DragonArt(
      future:
          ddragon?.championSquare(stats.championKey, championName: champion),
      size: _detailPortraitSize,
      borderRadius: BorderRadius.circular(tokens.radiusControl),
      placeholder: placeholder,
    );
  }
}

/// The final item build: icons ordered by [MatchItemSlot.slot], each real
/// Data Dragon art when [ddragon] resolves one, else a plain muted square —
/// there's no meaningful monogram for an item (no name kept locally, only
/// the numeric id — see [MatchItemSlot]'s doc), so the fallback is a blank
/// tile rather than invented text.
class _ItemBuild extends StatelessWidget {
  final DDragon? ddragon;
  final List<MatchItemSlot> items;

  const _ItemBuild({required this.ddragon, required this.items});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final sorted = [...items]..sort((a, b) => a.slot.compareTo(b.slot));
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final item in sorted)
          Container(
            width: _itemIconSize,
            height: _itemIconSize,
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(tokens.radiusControl),
              border: Border.all(color: tokens.hairline),
            ),
            child: DragonArt(
              future: ddragon?.itemIcon(item.itemId),
              size: _itemIconSize,
              borderRadius: BorderRadius.circular(tokens.radiusControl),
              placeholder: const SizedBox.shrink(),
            ),
          ),
      ],
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

  /// Source of champion/item art. Null (every test that doesn't care about
  /// art, and any build before `main.dart` threads one through) always
  /// renders the monogram/blank fallbacks.
  final DDragon? ddragon;

  const MatchClipsScreen({
    required this.session,
    required this.matchLabel,
    required this.stats,
    required this.library,
    this.thumbnails,
    this.ddragon,
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
            _MatchInfoCard(stats: s, ddragon: ddragon),
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
