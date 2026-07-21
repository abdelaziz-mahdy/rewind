import 'dart:io';

import 'package:flutter/material.dart';

import '../../clip/clip.dart';
import '../../clip/clip_library.dart';
import '../../clip/clip_trimmer.dart';
import '../../clip/filmstrip.dart';
import '../../clip/match_stats.dart';
import '../../clip/thumbnail_cache.dart';
import '../clip_file_actions.dart';
import '../../events/game_catalog.dart';
import '../../events/game_event.dart';
import '../player_screen.dart';
import '../theme.dart';

/// "pentaKill" -> "PENTA KILL".
String eventBadge(GameEventKind kind) => kind.name
    .replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
    .toUpperCase();

/// "just now" / "N min ago" / "N h ago" / a plain date once a day has passed.
String relativeAge(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}

/// "N.N MB" under 10 MB (one decimal), "N MB" at or above.
String formatSize(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}

/// Badge tint per event kind, derived from the single accent color by
/// rotating its hue (kills warm to amber, objectives shift to violet) so the
/// library stays legible at a glance without turning into an RGB rainbow.
Color eventColor(BuildContext context, GameEventKind kind) {
  final scheme = Theme.of(context).colorScheme;
  switch (kind) {
    case GameEventKind.manual:
    case GameEventKind.recording:
    case GameEventKind.victory:
      return scheme.primary;
    case GameEventKind.defeat:
    case GameEventKind.death:
      return scheme.error;
    case GameEventKind.matchInfo:
    case GameEventKind.statsUpdate:
    case GameEventKind.other:
      return scheme.outline;
    // The multikill ladder shares one amber HUE FAMILY (so every combat
    // highlight reads as "a kill"), but climbs toward a brighter, more
    // saturated gold as the tier rises — a pentakill must be unmistakable
    // next to a plain kill, not pixel-identical to it (they were, until the
    // watcher started emitting real tiers). ace stays at base amber: it's a
    // team event, not a personal multikill, so it shouldn't masquerade as a
    // penta.
    case GameEventKind.kill:
    case GameEventKind.ace:
      return _combatAmber(scheme.primary, 0);
    case GameEventKind.doubleKill:
      return _combatAmber(scheme.primary, 1);
    case GameEventKind.tripleKill:
      return _combatAmber(scheme.primary, 2);
    case GameEventKind.quadraKill:
      return _combatAmber(scheme.primary, 3);
    case GameEventKind.pentaKill:
      return _combatAmber(scheme.primary, 4);
    case GameEventKind.achievement:
      // A distinct gold arm — close enough to combat's amber to read as
      // "also a highlight", far enough (32 -> 48) to tell an achievement
      // badge apart from a kill badge at a glance.
      return _rotateAccent(scheme.primary, 48); // gold
    case GameEventKind.dragonKill:
    case GameEventKind.dragonSteal:
    case GameEventKind.baronKill:
    case GameEventKind.baronSteal:
    case GameEventKind.turretKill:
    case GameEventKind.inhibitorKill:
      return _rotateAccent(scheme.primary, 266); // violet
  }
}

Color _rotateAccent(Color accent, double hue) =>
    HSLColor.fromColor(accent).withHue(hue % 360).toColor();

/// The combat-highlight color for multikill [tier] (0 = single kill … 4 =
/// pentakill). Base is the same amber as [_rotateAccent](…, 32); each tier
/// nudges the hue toward gold and lifts saturation + lightness, so the
/// ladder reads as one family that visibly intensifies — a penta glows
/// brighter than a double. Lightness climbs from the accent's own value but
/// is capped so the brightest tier stays legible on the badge's dark fill.
Color _combatAmber(Color accent, int tier) {
  final base = HSLColor.fromColor(accent);
  return HSLColor.fromAHSL(
    1,
    (32 + tier * 3) % 360,
    (base.saturation + tier * 0.03).clamp(0.0, 1.0),
    (base.lightness + tier * 0.05).clamp(0.0, 0.72),
  ).toColor();
}

/// The event-kind badge chip: accent-tinted fill/border, uppercase micro-label
/// text (see [eventBadge]/[eventColor]). Shared by [ClipTile]'s thumbnail
/// overlay, [PlayerScreen]'s header, and the game hub's live-events slot so
/// a clip's event reads identically everywhere it appears.
class EventBadge extends StatelessWidget {
  final GameEventKind kind;

  const EventBadge({required this.kind, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = eventColor(context, kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(context.rewindTokens.radiusChip),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Text(
        eventBadge(kind),
        style: theme.textTheme.micro.copyWith(color: accent),
      ),
    );
  }
}

enum _ClipAction { openDefault, reveal, protect, delete }

/// Grid geometry for the clip card grid (maintainer: "instead of list, a
/// grid will make more sense for the recording"). [clipGridMaxCrossAxisExtent]
/// / [clipGridSpacing] feed `SliverGridDelegateWithMaxCrossAxisExtent`
/// directly at both grid call sites (`all_clips_screen.dart`,
/// `game_hub_screen.dart`). [clipGridChildAspectRatio] is derived from the
/// card's own fixed geometry — a 16:9 thumbnail plus a [_footerHeight]
/// footer — rather than guessed, so a card never overflows at any column
/// count the delegate picks for a given viewport width (the delegate always
/// assumes [clipGridMaxCrossAxisExtent] as the per-card width when applying
/// this ratio). Verified with no layout overflow in clip_tile_test.dart via
/// `tester.getSize`/`tester.takeException`.
const double clipGridMaxCrossAxisExtent = 300;
const double clipGridSpacing = 16;
const double _footerHeight = 56;
const double clipGridChildAspectRatio = clipGridMaxCrossAxisExtent /
    (clipGridMaxCrossAxisExtent * 9 / 16 + _footerHeight);

/// One card in the clip grid: a 16:9 thumbnail (the existing [ThumbnailCache]
/// image, or a placeholder glyph while absent/pending) with a centered
/// play-glyph overlay, the event badge pinned top-left over it, and a
/// hover-revealed overflow (⋯) menu top-right offering the same actions as
/// before (open in default player / reveal / delete). A footer row below the
/// thumbnail shows relative age + size, plus the game name when
/// [showGameName] is true — All Clips passes true (a cross-game list, where
/// the game name is the only way to tell clips apart); each game hub passes
/// false (its clip list is already scoped to one game, so repeating that
/// game's name on every card would be redundant). Tap anywhere on the card
/// opens the clip in the in-app [PlayerScreen] — same navigation contract as
/// before (a route pushed under [playerScreenRouteName], never actually
/// built in widget tests — see that constant's doc).
class ClipTile extends StatefulWidget {
  final Clip clip;
  final ClipLibrary library;

  /// Source of thumbnails. Null (the default in every test that doesn't
  /// care about thumbnails) always renders the placeholder — real call
  /// sites thread a shared cache down from `main.dart`.
  final ThumbnailCache? thumbnails;

  /// Whether the footer shows the clip's game name (see class doc).
  final bool showGameName;

  /// The clip's match events (see `MatchStats.events`), forwarded to
  /// `PlayerScreen` on open so it can draw timeline markers. Empty (the
  /// default) for any caller with no `MatchStats` handy — that's not an
  /// error, just a plain seek bar (see `clip_markers.dart`'s honesty note).
  final List<MatchEventStamp> events;

  const ClipTile({
    required this.clip,
    required this.library,
    this.thumbnails,
    this.showGameName = true,
    this.events = const [],
    super.key,
  });

  @override
  State<ClipTile> createState() => _ClipTileState();
}

class _ClipTileState extends State<ClipTile> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final clip = widget.clip;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      // InkWell needs a Material ancestor it can paint ink on; without one,
      // Flutter's "ink splashes may be invisible" assertion fires (the same
      // reason the old row layout wrapped its ListTile in one).
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () =>
              _openInApp(context, clip, widget.events, library: widget.library),
          onFocusChange: (focused) => setState(() => _focused = focused),
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: _hovering ? tokens.surfaceRaised : tokens.surface,
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              // Focus gets its own 1.5 px accent border (keyboard-only
              // affordance — see docs/superpowers/specs/
              // 2026-07-13-game-centric-redesign.md §2); hover only swaps
              // the fill above, no border change.
              border: Border.fromBorderSide(_focused
                  ? BorderSide(color: tokens.accent, width: 1.5)
                  : hairlineBorder()),
            ),
            // ClipRRect (not Container.clipBehavior) so the thumbnail
            // image's corners round to match the card — `Container.
            // clipBehavior` needs the `Clip` enum, which the app's own
            // `Clip` model class (imported above) shadows in this file.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Expanded (not AspectRatio) deliberately: the grid
                  // delegate's mainAxisExtent for a cell is derived from
                  // [clipGridChildAspectRatio], which assumes a card exactly
                  // [clipGridMaxCrossAxisExtent] wide — but
                  // SliverGridDelegateWithMaxCrossAxisExtent can hand a cell
                  // a narrower actual width (its column-count step function),
                  // at which point a strict 16:9 AspectRatio plus this fixed-
                  // height footer no longer summed to the height the grid
                  // allocated, overflowing by a few px. Expanded instead
                  // fills whatever height remains after the footer — exactly
                  // 16:9 at the assumed width, a close approximation
                  // elsewhere, and never overflows.
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipThumbnail(
                            clip: clip, thumbnails: widget.thumbnails),
                        Positioned(
                          left: 8,
                          top: 8,
                          child: EventBadge(kind: clip.event),
                        ),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            // Dimmed at rest, not invisible: a fully hidden
                            // menu has zero affordance for anyone not
                            // already hovering the card.
                            opacity: _hovering ? 1 : 0.45,
                            child: _OverflowMenu(
                              protected: clip.protected,
                              onSelected: (action) =>
                                  _onAction(context, action),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: _footerHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.showGameName) ...[
                            Text(
                              displayNameFor(clip.gameId),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: theme.textTheme.body
                                  .copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                          ],
                          Row(
                            children: [
                              if (clip.protected) ...[
                                // Pinned against auto-cleanup (see the
                                // overflow menu's Protect action).
                                Icon(
                                  Icons.bookmark,
                                  key: const ValueKey('protectedLock'),
                                  size: 11,
                                  color: tokens.textMuted,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  // The badge only ever says the generic
                                  // "ACHIEVEMENT" (eventBadge's plain kind-
                                  // casing) — the SPECIFIC unlock name (e.g.
                                  // "Winner Winner", see
                                  // `SteamAchievementWatcher`/
                                  // `Clip.eventLabel`) leads this line
                                  // instead, same single-row/ellipsis
                                  // treatment as everything else here.
                                  '${clip.eventLabel != null ? '${clip.eventLabel} · ' : ''}'
                                  '${relativeAge(clip.createdAt)} · '
                                  '${formatSize(clip.sizeBytes)}'
                                  '${clip.killCount > 0 ? ' · ${clip.killCount} '
                                      '${clip.killCount == 1 ? 'kill' : 'kills'}' : ''}',
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: theme.textTheme.bodyMuted,
                                ),
                              ),
                            ],
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

  Future<void> _onAction(BuildContext context, _ClipAction action) async {
    switch (action) {
      case _ClipAction.openDefault:
        if (!await openClipFile(widget.clip.path) && context.mounted) {
          showOpenFailedToast(context);
        }
      case _ClipAction.reveal:
        if (!await revealClipFile(widget.clip.path) && context.mounted) {
          showOpenFailedToast(context);
        }
      case _ClipAction.protect:
        // Protected clips are exempt from StorageManager's auto-cleanup
        // (max-storage / max-age pruning) — the ShadowPlay-style "keep this
        // one forever" pin. setState so the lock badge appears immediately;
        // save persists the flag across restarts.
        widget.library.setProtected(widget.clip, !widget.clip.protected);
        setState(() {});
        await widget.library.save();
      case _ClipAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete clip?'),
            content: const Text('This permanently deletes the clip file.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              // Destructive action reads as destructive — identical plain
              // buttons invited misclicks on a permanent file delete.
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) await widget.library.deleteClip(widget.clip);
    }
  }

  static void _openInApp(
      BuildContext context, Clip clip, List<MatchEventStamp> events,
      {ClipLibrary? library}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: playerScreenRouteName),
      builder: (_) => PlayerScreen(
        clip: clip,
        events: events,
        library: library,
        // The real platform exporter; PlayerScreen hides Trim wherever
        // it reports unsupported (Linux, until ffmpeg_kit ships binaries).
        trimmer: FfmpegKitClipTrimmer(),
        filmstrip: FfmpegFilmstripGenerator(),
      ),
    ));
  }
}

/// The hover-revealed overflow trigger pinned over the thumbnail: a dark
/// scrim behind the icon so it stays legible over any video frame, since
/// unlike the old row layout it now sits directly on top of image content
/// rather than on the flat surface background.
class _OverflowMenu extends StatelessWidget {
  final ValueChanged<_ClipAction> onSelected;

  /// Whether the clip is currently pinned against auto-cleanup — flips the
  /// protect item's label.
  final bool protected;

  const _OverflowMenu({required this.onSelected, required this.protected});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(context.rewindTokens.radiusChip),
      ),
      child: PopupMenuButton<_ClipAction>(
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_vert, size: 18, color: Colors.white),
        onSelected: onSelected,
        itemBuilder: (context) => [
          const PopupMenuItem(
              value: _ClipAction.openDefault,
              child: Text('Open in default player')),
          PopupMenuItem(
            value: _ClipAction.reveal,
            child: Text(
                Platform.isMacOS ? 'Reveal in Finder' : 'Reveal in Explorer'),
          ),
          PopupMenuItem(
            value: _ClipAction.protect,
            child: Text(protected ? 'Stop keeping' : 'Keep'),
          ),
          const PopupMenuItem(value: _ClipAction.delete, child: Text('Delete')),
        ],
      ),
    );
  }
}

/// The card's 16:9 thumbnail area: a real video-frame image once generated,
/// with a centered play-glyph overlay; the original bare play-glyph
/// placeholder while absent (no [thumbnails] cache — most tests — or the
/// frame hasn't been generated yet). [FutureBuilder] on [ThumbnailCache.ensure]
/// is deliberate: it starts on the placeholder and swaps to the image the
/// moment generation completes, with no extra listenable plumbing needed.
/// Fills whatever space its parent [Expanded]/[Stack] gives it — sizing
/// and corner-rounding are the card's job, not this widget's.
class ClipThumbnail extends StatelessWidget {
  final Clip clip;
  final ThumbnailCache? thumbnails;

  const ClipThumbnail(
      {required this.clip, required this.thumbnails, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cache = thumbnails;
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: cache == null
          ? _playGlyph(theme.colorScheme.onSurfaceVariant)
          : FutureBuilder<File?>(
              future: cache.ensure(clip),
              builder: (context, snapshot) {
                final file = snapshot.data;
                if (file == null) {
                  return _playGlyph(theme.colorScheme.onSurfaceVariant);
                }
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(file, fit: BoxFit.cover),
                    _playGlyph(Colors.white.withValues(alpha: 0.85)),
                  ],
                );
              },
            ),
    );
  }

  Widget _playGlyph(Color color) => Center(
        child: Icon(Icons.play_arrow_rounded, size: 36, color: color),
      );
}
