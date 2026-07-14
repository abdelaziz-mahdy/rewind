import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import '../log/log.dart';
import '../obs/app_info.dart';
import '../obs/display_info.dart';
import '../settings/app_settings.dart';
import 'all_clips_screen.dart';
import 'settings_screen.dart';
import 'shell_destination.dart';
import 'theme.dart';
import 'widgets/nav_rail.dart';
import 'widgets/status_strip.dart';

/// The app's persistent scaffold (§3.1): a 220 px left rail + the recorder
/// deck (`StatusStrip`) pinned above a content area that swaps on a sealed
/// [ShellDestination] — plain `StatefulWidget` navigation, no router package.
/// Owns the save-error SnackBar listener (moved here from the old
/// `HomeScreen` so it fires on every destination, not just All Clips).
class Shell extends StatefulWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;
  final String? captureError;

  /// Live buffer state (toggled by the tray's pause/resume). When null the
  /// deck assumes the buffer is running iff capture came up without error.
  final ValueListenable<bool>? bufferActive;
  final String hotkeyLabel;

  /// Connected displays / capturable apps, forwarded to the status strip's
  /// capture-source chip and the embedded Settings destination.
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;

  /// Persists a settings change (mutated in place) — used by the
  /// capture-source chip, the buffer quick-set, and embedded Settings.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Reveals the clips folder in the OS file manager — wired to All Clips'
  /// header button and its empty-state button.
  final VoidCallback onOpenClipsFolder;

  /// Forwarded to [StatusStrip.settingsRevision] and [NavRail] (the rail's
  /// game list must refresh after an in-place settings mutation too, e.g. a
  /// per-game buffer edit). Optional — see [StatusStrip]'s doc.
  final ValueListenable<int>? settingsRevision;

  /// Forwarded to the embedded Settings destination's hotkey recorder.
  final Future<void> Function(bool recording)? onHotkeyRecording;

  const Shell({
    required this.coordinator,
    required this.library,
    this.captureError,
    this.bufferActive,
    required this.hotkeyLabel,
    this.displays = const [],
    this.capturableApps = const [],
    required this.onSettingsChanged,
    required this.onOpenClipsFolder,
    this.settingsRevision,
    this.onHotkeyRecording,
    super.key,
  });

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  ShellDestination _destination = const AllClipsDestination();

  @override
  void initState() {
    super.initState();
    widget.coordinator.lastSaveError.addListener(_showSaveErrorIfAny);
  }

  @override
  void dispose() {
    widget.coordinator.lastSaveError.removeListener(_showSaveErrorIfAny);
    super.dispose();
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

  void _select(ShellDestination destination) =>
      setState(() => _destination = destination);

  void _openLogs() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => TalkerScreen(
        talker: talker,
        theme: TalkerScreenTheme.fromTheme(Theme.of(context)),
      ),
    ));
  }

  static String _destinationKey(ShellDestination d) => switch (d) {
        AllClipsDestination() => 'allClips',
        GameDestination(gameId: final id) => 'game:$id',
        SupportedGamesDestination() => 'supportedGames',
        SettingsDestination() => 'settings',
      };

  Widget _content(BuildContext context) {
    return switch (_destination) {
      AllClipsDestination() => AllClipsScreen(
          key: const ValueKey('allClipsScreen'),
          library: widget.library,
          hotkeyLabel: widget.hotkeyLabel,
          onOpenClipsFolder: widget.onOpenClipsFolder,
        ),
      GameDestination(gameId: final id) => AllClipsScreen(
          key: ValueKey('gameClipsScreen:$id'),
          library: widget.library,
          hotkeyLabel: widget.hotkeyLabel,
          onOpenClipsFolder: widget.onOpenClipsFolder,
          gameId: id,
        ),
      // Supported Games is built in T5; this is the explicit interim empty
      // pane the T3 brief allows for a not-yet-built destination.
      SupportedGamesDestination() => const _ComingSoonPane(
          key: ValueKey('supportedGamesPane'),
          label: 'Supported Games',
        ),
      SettingsDestination() => SettingsScreen(
          key: const ValueKey('settingsScreen'),
          settings: widget.coordinator.settings,
          onChanged: widget.onSettingsChanged,
          displays: widget.displays,
          capturableApps: widget.capturableApps,
          onHotkeyRecording: widget.onHotkeyRecording,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NavRail(
            coordinator: widget.coordinator,
            library: widget.library,
            settingsRevision: widget.settingsRevision,
            selected: _destination,
            onSelect: _select,
            onOpenLogs: _openLogs,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatusStrip(
                  coordinator: widget.coordinator,
                  captureError: widget.captureError,
                  bufferActive: widget.bufferActive,
                  displays: widget.displays,
                  capturableApps: widget.capturableApps,
                  onSettingsChanged: widget.onSettingsChanged,
                  onOpenSettings: () => _select(const SettingsDestination()),
                  settingsRevision: widget.settingsRevision,
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: KeyedSubtree(
                      key: ValueKey(_destinationKey(_destination)),
                      child: _content(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Supported Games / other not-yet-built destinations' placeholder: a
/// bare "coming in this build" pane, per the T3 brief — no invented catalog
/// UI ahead of T5.
class _ComingSoonPane extends StatelessWidget {
  final String label;

  const _ComingSoonPane({required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        '$label — coming in this build',
        style: theme.textTheme.body
            .copyWith(color: context.rewindTokens.textMuted),
      ),
    );
  }
}
