import 'package:flutter/material.dart';

import '../../clip/match_stats.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/dragon_art.dart';
import '../../ui/widgets/game_tile_avatar.dart';
import '../match_presentation.dart';
import 'ddragon.dart';
import 'game_modes.dart';

const double _summaryPortraitSize = 40;
const double _summaryItemIconSize = 20;

/// Whether [stats] has anything worth a K/D/A/CS/WS line — an early-game
/// match with all zeros must not read "0 K · 0 D · ...".
bool _hasStatLine(MatchStats stats) =>
    stats.kills > 0 ||
    stats.deaths > 0 ||
    stats.assists > 0 ||
    stats.creepScore > 0 ||
    stats.wardScore > 0;

/// "12 K · 3 D · 7 A · 120 CS · 14.5 WS" — only the pieces that are actually
/// non-zero. See [_hasStatLine].
String _statLine(MatchStats stats) {
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

/// The compact match summary at the top of the drill-down: champion portrait
/// + skin + mode headline on the left, the K/D/A line and final item build on
/// the right — one band instead of the roster-dominated card this replaced
/// (see docs on the game-centric redesign). Renders only the pieces that
/// [stats] actually has (a match with no champion resolved shows no
/// portrait/headline; no live stats shows no K/D/A/items column), so a
/// process game or an early poll degrades gracefully instead of showing
/// empty furniture.
class _MatchSummaryBand extends StatelessWidget {
  final MatchStats stats;
  final DDragon? ddragon;

  const _MatchSummaryBand({required this.stats, required this.ddragon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final champion = stats.champion;
    // Resolved at render, never from storage — see games/league/game_modes.dart.
    final mode = friendlyLeagueGameMode(stats.gameMode);
    final headline = [
      if (champion != null) champion,
      if (mode != null) mode,
    ].join(' · ');
    final hasStatLine = _hasStatLine(stats);
    final hasItems = stats.items.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        border: Border.fromBorderSide(hairlineBorder()),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (champion != null) ...[
            _ChampionPortraitLarge(
              ddragon: ddragon,
              stats: stats,
              size: _summaryPortraitSize,
            ),
            const SizedBox(width: 10),
          ],
          if (headline.isNotEmpty)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(headline,
                      style: theme.textTheme.title,
                      overflow: TextOverflow.ellipsis),
                  if (stats.skinName case final skin? when skin.isNotEmpty)
                    Text(skin,
                        style: theme.textTheme.micro
                            .copyWith(color: tokens.textMuted),
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            )
          else
            const Spacer(),
          if (hasStatLine || hasItems) ...[
            const SizedBox(width: 12),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (hasStatLine)
                  Text(_statLine(stats), style: theme.textTheme.body),
                if (hasItems) ...[
                  if (hasStatLine) const SizedBox(height: 6),
                  _ItemBuild(
                    ddragon: ddragon,
                    items: stats.items,
                    iconSize: _summaryItemIconSize,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The champion portrait in the match summary band: real Data Dragon art
/// when [ddragon] resolves one, else a monogram — same fallback contract as
/// `GameTileAvatar`.
class _ChampionPortraitLarge extends StatelessWidget {
  final DDragon? ddragon;
  final MatchStats stats;
  final double size;

  const _ChampionPortraitLarge({
    required this.ddragon,
    required this.stats,
    required this.size,
  });

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
          fontSize: size * 0.36,
          letterSpacing: -0.2,
          height: 1,
        ),
      ),
    );
    return DragonArt(
      future:
          ddragon?.championSquare(stats.championKey, championName: champion),
      size: size,
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
  final double iconSize;

  const _ItemBuild({
    required this.ddragon,
    required this.items,
    required this.iconSize,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final sorted = [...items]..sort((a, b) => a.slot.compareTo(b.slot));
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final item in sorted)
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(tokens.radiusControl),
              border: Border.all(color: tokens.hairline),
            ),
            child: DragonArt(
              future: ddragon?.itemIcon(item.itemId),
              size: iconSize,
              borderRadius: BorderRadius.circular(tokens.radiusControl),
              placeholder: const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}

/// The roster, collapsed behind a chevron-toggle row by default — the
/// teammates'/enemies' champions are rarely what a maintainer opens a match
/// for, so they no longer dominate the screen (see the compact summary band
/// above). Mirrors `settings_screen.dart`'s `_AdvancedDisclosure` interaction
/// (chevron rotation + `AnimatedSize` reveal); kept as its own small widget
/// here rather than sharing code, since the two disclosures' labels and
/// content differ enough that extracting a common base would mostly just
/// move the diff around. Owns its own open/closed state (rather than the
/// hosting screen owning it) now that it's reached through the
/// [MatchPresentation] seam instead of being inlined in the screen.
class _RosterDisclosure extends StatefulWidget {
  final MatchStats stats;

  const _RosterDisclosure({required this.stats});

  @override
  State<_RosterDisclosure> createState() => _RosterDisclosureState();
}

class _RosterDisclosureState extends State<_RosterDisclosure> {
  bool _open = false;

  /// Every other champion in the match — teammates, opponents, or (in
  /// team-less modes like Arena) everyone else in one list. Excludes the
  /// player themself, who's already shown in the summary band above.
  int get _rosterSize =>
      widget.stats.allies.length + widget.stats.enemies.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('rosterDisclosure'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.chevron_right,
                        size: 16, color: tokens.textMuted),
                  ),
                  const SizedBox(width: 6),
                  Text('Champions in this game ($_rosterSize)',
                      style: theme.textTheme.body
                          .copyWith(color: tokens.textMuted)),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topLeft,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _chips(context),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _chips(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;

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

    final stats = widget.stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A real 2-team split (Summoner's Rift, ARAM) shows YOUR TEAM vs
        // ENEMIES. Arena and other multi-team modes have no reliable team
        // data (see LeagueEventWatcher), so allies is empty and every other
        // champion lands in one neutral list.
        if (stats.allies.isNotEmpty) ...[
          team('YOUR TEAM', stats.allies, tokens.accent),
          if (stats.enemies.isNotEmpty) ...[
            const SizedBox(height: 16),
            team('ENEMIES', stats.enemies, theme.colorScheme.error),
          ],
        ] else if (stats.enemies.isNotEmpty)
          team('CHAMPIONS IN THIS GAME', stats.enemies, tokens.textMuted),
      ],
    );
  }
}

/// League's [MatchPresentation]: the summary band, roster disclosure, and
/// kills footnote that used to be inlined in `MatchClipsScreen` — moved
/// here byte-for-byte (including the footnote's stats-existence gating from
/// e90a86f) as the first per-game presentation impl.
class LeagueMatchPresentation extends MatchPresentation {
  /// Source of champion/item art. Null (every test that doesn't care about
  /// art, and any build before `main.dart` threads one through) always
  /// renders the monogram/blank fallbacks.
  final DDragon? ddragon;

  const LeagueMatchPresentation({this.ddragon});

  @override
  Widget? buildSummary(BuildContext context, MatchStats stats) {
    final showBand = stats.champion != null ||
        stats.gameMode != null ||
        _hasStatLine(stats) ||
        stats.items.isNotEmpty;
    if (!showBand) return null;
    return _MatchSummaryBand(stats: stats, ddragon: ddragon);
  }

  @override
  Widget? buildExtras(BuildContext context, MatchStats stats) {
    final hasRoster = stats.allies.isNotEmpty || stats.enemies.isNotEmpty;
    if (!hasRoster) return null;
    return _RosterDisclosure(stats: stats);
  }

  @override
  String? footnote(MatchStats? stats) {
    // Only when the match actually HAS live-tracked stats: the line
    // explains League's Live-Client kill counting, and rendering it on a
    // process-detected game's session ("Kills counted from the live game"
    // with no live game feed in sight) was plain wrong.
    if (stats == null) return null;
    return 'Kills counted from the live game, even for fights not clipped.';
  }
}
