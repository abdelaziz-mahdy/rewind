import 'dart:io';

import 'package:flutter/material.dart';

import '../../clip/clip.dart';
import '../../clip/clip_library.dart';
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
    case GameEventKind.victory:
      return scheme.primary;
    case GameEventKind.defeat:
      return scheme.error;
    case GameEventKind.other:
      return scheme.outline;
    case GameEventKind.kill:
    case GameEventKind.doubleKill:
    case GameEventKind.tripleKill:
    case GameEventKind.quadraKill:
    case GameEventKind.pentaKill:
    case GameEventKind.ace:
      return _rotateAccent(scheme.primary, 32); // amber
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

/// The event-kind badge chip: accent-tinted fill/border, uppercase micro-label
/// text (see [eventBadge]/[eventColor]). Shared by [ClipTile]'s title row,
/// [PlayerScreen]'s header, and the game hub's live-events slot so a clip's
/// event reads identically everywhere it appears.
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

enum _ClipAction { openDefault, reveal, delete }

/// One row in the clip library: thumbnail placeholder, event badge + game
/// name, relative age + size, and a menu for reveal/delete. Tap opens the
/// clip in the in-app [PlayerScreen]; the overflow menu still offers
/// launching the OS default player for anyone who wants an external app.
/// The trailing menu fades in on hover so the row stays clean at rest.
class ClipTile extends StatefulWidget {
  final Clip clip;
  final ClipLibrary library;

  const ClipTile({required this.clip, required this.library, super.key});

  @override
  State<ClipTile> createState() => _ClipTileState();
}

class _ClipTileState extends State<ClipTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clip = widget.clip;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hovering
              ? context.rewindTokens.surfaceRaised
              : Colors.transparent,
          border: Border(bottom: hairlineBorder(0.06)),
        ),
        // ListTile needs a Material ancestor it can paint ink on; the
        // decorated AnimatedContainer above otherwise triggers Flutter's
        // "ink splashes may be invisible" assertion on every tile.
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
            onTap: () => _openInApp(context, clip),
            leading: Container(
              width: 64,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius:
                    BorderRadius.circular(context.rewindTokens.radiusChip),
                border: Border.fromBorderSide(hairlineBorder()),
              ),
              child: Icon(Icons.play_arrow_rounded,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                EventBadge(kind: clip.event),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    displayNameFor(clip.gameId),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.body
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              '${relativeAge(clip.createdAt)} · ${formatSize(clip.sizeBytes)}',
              style: theme.textTheme.bodyMuted,
            ),
            trailing: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: _hovering ? 1 : 0.55,
              child: PopupMenuButton<_ClipAction>(
                onSelected: (action) => _onAction(context, action),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                      value: _ClipAction.openDefault,
                      child: Text('Open in default player')),
                  PopupMenuItem(
                    value: _ClipAction.reveal,
                    child: Text(Platform.isMacOS
                        ? 'Reveal in Finder'
                        : 'Reveal in Explorer'),
                  ),
                  const PopupMenuItem(
                      value: _ClipAction.delete, child: Text('Delete')),
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
        await _open(widget.clip.path);
      case _ClipAction.reveal:
        await _reveal(widget.clip.path);
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
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) await widget.library.deleteClip(widget.clip);
    }
  }

  static void _openInApp(BuildContext context, Clip clip) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: playerScreenRouteName),
      builder: (_) => PlayerScreen(clip: clip),
    ));
  }

  static Future<void> _open(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        // `start` is a cmd.exe built-in, not an executable; a quoted first
        // arg is taken as the window title, so pass an empty title first.
        await Process.run('cmd', ['/c', 'start', '', path]);
      }
    } catch (_) {
      // Best-effort: no OS handler available is not fatal.
    }
  }

  static Future<void> _reveal(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        // Documented form: "/select," joined with the path as ONE argument.
        await Process.run('explorer', ['/select,$path']);
      }
    } catch (_) {
      // Best-effort: no OS handler available is not fatal.
    }
  }
}
