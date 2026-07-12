import 'dart:io';

import 'package:flutter/material.dart';

import '../../clip/clip.dart';
import '../../clip/clip_library.dart';
import '../../events/game_event.dart';

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

enum _ClipAction { reveal, delete }

/// One row in the clip library: thumbnail placeholder, event badge + game
/// name, relative age + size, and a menu for reveal/delete. Tap opens the
/// clip with the OS default player.
class ClipTile extends StatelessWidget {
  final Clip clip;
  final ClipLibrary library;

  const ClipTile({required this.clip, required this.library, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: () => _open(clip.path),
      leading: Container(
        width: 64,
        height: 44,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.play_arrow_rounded),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              eventBadge(clip.event),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(clip.gameId, overflow: TextOverflow.ellipsis)),
        ],
      ),
      subtitle: Text(
          '${relativeAge(clip.createdAt)} · ${formatSize(clip.sizeBytes)}'),
      trailing: PopupMenuButton<_ClipAction>(
        onSelected: (action) => _onAction(context, action),
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _ClipAction.reveal,
            child: Text(
                Platform.isMacOS ? 'Reveal in Finder' : 'Reveal in Explorer'),
          ),
          const PopupMenuItem(value: _ClipAction.delete, child: Text('Delete')),
        ],
      ),
    );
  }

  Future<void> _onAction(BuildContext context, _ClipAction action) async {
    switch (action) {
      case _ClipAction.reveal:
        await _reveal(clip.path);
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
        if (confirmed == true) await library.deleteClip(clip);
    }
  }

  static Future<void> _open(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('start', [path], runInShell: true);
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
        await Process.run('explorer', ['-R', path]);
      }
    } catch (_) {
      // Best-effort: no OS handler available is not fatal.
    }
  }
}
