import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import '../log/log.dart';
import '../obs/app_info.dart';
import '../obs/display_info.dart';
import '../settings/app_settings.dart';
import 'widgets/clip_tile.dart';
import 'widgets/game_filter_rail.dart';
import 'widgets/status_strip.dart';

/// The main window: status strip up top, clip library below.
class HomeScreen extends StatefulWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;
  final String? captureError;

  /// Live buffer state (toggled by the tray's pause/resume). When null the
  /// strip assumes the buffer is running iff capture came up without error.
  final ValueListenable<bool>? bufferActive;
  final String hotkeyLabel;
  final VoidCallback onOpenSettings;

  /// Connected displays / capturable apps, forwarded to the status strip's
  /// capture-source chip (see [StatusStrip]). Defaults to empty so existing
  /// callers/tests that don't care about capture-source switching don't need
  /// to wire it.
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;

  /// Persists a settings change (mutated in place) — used by the
  /// capture-source chip and the buffer quick-set.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Reveals the clips folder in the OS file manager — wired to the AppBar
  /// folder button and the empty-state's text button.
  final VoidCallback onOpenClipsFolder;

  const HomeScreen({
    required this.coordinator,
    required this.library,
    this.captureError,
    this.bufferActive,
    required this.hotkeyLabel,
    required this.onOpenSettings,
    this.displays = const [],
    this.capturableApps = const [],
    required this.onSettingsChanged,
    required this.onOpenClipsFolder,
    super.key,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Selected gameId in the filter rail; null means "All". Reset to null
  /// whenever its game has no clips left (e.g. its last clip was deleted).
  String? _filterGameId;

  @override
  void initState() {
    super.initState();
    widget.coordinator.lastSaveError.addListener(_showSaveErrorIfAny);
    widget.library.addListener(_pruneFilterIfGameGone);
  }

  @override
  void dispose() {
    widget.coordinator.lastSaveError.removeListener(_showSaveErrorIfAny);
    widget.library.removeListener(_pruneFilterIfGameGone);
    super.dispose();
  }

  void _pruneFilterIfGameGone() {
    final filter = _filterGameId;
    if (filter == null) return;
    final stillPresent = widget.library.all.any((c) => c.gameId == filter);
    if (!stillPresent && mounted) {
      setState(() => _filterGameId = null);
    }
  }

  void _showSaveErrorIfAny() {
    if (!mounted) return;
    final message = widget.coordinator.lastSaveError.value;
    if (message == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Theme.of(context).colorScheme.error,
      content: Text("Couldn't save clip: $message"),
    ));
  }

  void _openLogs() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => TalkerScreen(
        talker: talker,
        theme: TalkerScreenTheme.fromTheme(Theme.of(context)),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewind'),
        actions: [
          IconButton(
            tooltip: 'Open clips folder',
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: widget.onOpenClipsFolder,
          ),
          IconButton(
            tooltip: 'Logs',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: _openLogs,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          StatusStrip(
            coordinator: widget.coordinator,
            captureError: widget.captureError,
            bufferActive: widget.bufferActive,
            displays: widget.displays,
            capturableApps: widget.capturableApps,
            onSettingsChanged: widget.onSettingsChanged,
            onOpenSettings: widget.onOpenSettings,
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.library,
              builder: (context, _) {
                final all = widget.library.all;
                if (all.isEmpty) {
                  return _EmptyLibrary(
                    hotkeyLabel: widget.hotkeyLabel,
                    onOpenClipsFolder: widget.onOpenClipsFolder,
                  );
                }
                final filterId = _filterGameId;
                final visible = filterId == null
                    ? all
                    : all.where((c) => c.gameId == filterId).toList();
                final clips = List.of(visible)
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                // The rail is omitted entirely (not just visually hidden)
                // when it has nothing to offer: a library of nothing but
                // desktop clips has no game to filter by.
                final hasNonDesktopGame = all.any((c) => c.gameId != 'desktop');
                return Column(
                  children: [
                    if (hasNonDesktopGame)
                      GameFilterRail(
                        clips: all,
                        selected: _filterGameId,
                        onSelected: (id) => setState(() => _filterGameId = id),
                      ),
                    Expanded(
                      child: clips.isEmpty
                          ? _EmptyLibrary(
                              hotkeyLabel: widget.hotkeyLabel,
                              onOpenClipsFolder: widget.onOpenClipsFolder,
                            )
                          : ListView.builder(
                              itemCount: clips.length,
                              itemBuilder: (context, i) => ClipTile(
                                  clip: clips[i], library: widget.library),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  final String hotkeyLabel;
  final VoidCallback onOpenClipsFolder;

  const _EmptyLibrary({
    required this.hotkeyLabel,
    required this.onOpenClipsFolder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.movie_creation_outlined,
              size: 56, color: muted.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('No clips yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Press ',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              _KeyCap(label: hotkeyLabel),
              Text(' to save your last moment',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
            ],
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onOpenClipsFolder,
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Open clips folder'),
          ),
        ],
      ),
    );
  }
}

/// A hotkey rendered as a physical keyboard key: bordered cap with a
/// slightly darker "bottom edge" shadow, tabular figures for any digits.
class _KeyCap extends StatelessWidget {
  final String label;

  const _KeyCap({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
