import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import '../events/game_catalog.dart';
import '../log/log.dart';
import '../obs/app_info.dart';
import '../obs/display_info.dart';
import '../settings/app_settings.dart';
import 'all_clips_screen.dart';
import 'capture_app_match.dart';
import 'game_hub_screen.dart';
import 'settings_screen.dart';
import 'shell_destination.dart';
import 'supported_games_screen.dart';
import 'theme.dart';
import 'widgets/game_tile_avatar.dart';
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

  /// Points the live capture engine at a specific app, identified by
  /// [AppInfo.bundleId] — used by the detected-game banner's Record button
  /// to start capturing a game the moment it's confirmed, mirroring
  /// [ClipCoordinator]'s own "follow the game" auto-switch but triggered
  /// explicitly by the user's click rather than a background detection
  /// event. Does not persist [AppSettings.captureAppBundleId]; null when no
  /// capture backend is wired up (dev mode).
  final void Function(String bundleId)? onSetCaptureApp;

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
    this.onSetCaptureApp,
    super.key,
  });

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  ShellDestination _destination = const AllClipsDestination();

  /// Catalog games whose detected-game banner (see [_DetectedGameBanners])
  /// the user has dismissed this session. Session-scoped on purpose — a
  /// dismiss is "not now", not "never"; the banner returns next launch if
  /// the game is still unconfigured next time it's seen running.
  final Set<String> _dismissedBanners = {};

  void _dismissBanner(String gameId) =>
      setState(() => _dismissedBanners.add(gameId));

  /// The detected-game banner's Record button: configures [game] through the
  /// same `configFor` → `setConfig` → `onSettingsChanged` path every other
  /// "add this game" flow in the app uses (Supported Games' Add, the hub's
  /// per-game settings), then — if a currently-capturable app matches this
  /// game's process, using the same matching the coordinator's own
  /// auto-switch relies on — points capture at it immediately, and finally
  /// opens the game's hub so the user lands somewhere that confirms it
  /// worked.
  void _recordDetectedGame(CatalogGame game) {
    final settings = widget.coordinator.settings;
    final cfg = settings.configFor(game.gameId);
    settings.setConfig(cfg);
    widget.onSettingsChanged(settings);

    final match = findRunningApp(game.processMatch, widget.capturableApps);
    if (match != null) widget.onSetCaptureApp?.call(match.bundleId);

    _select(GameDestination(game.gameId));
  }

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
      GameDestination(gameId: final id) => GameHubScreen(
          key: ValueKey('gameHubScreen:$id'),
          gameId: id,
          library: widget.library,
          coordinator: widget.coordinator,
          hotkeyLabel: widget.hotkeyLabel,
          onSettingsChanged: widget.onSettingsChanged,
        ),
      SupportedGamesDestination() => SupportedGamesScreen(
          key: const ValueKey('supportedGamesScreen'),
          coordinator: widget.coordinator,
          library: widget.library,
          onSettingsChanged: widget.onSettingsChanged,
          onOpenGame: (gameId) => _select(GameDestination(gameId)),
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
                _DetectedGameBanners(
                  coordinator: widget.coordinator,
                  capturableApps: widget.capturableApps,
                  settingsRevision: widget.settingsRevision,
                  dismissed: _dismissedBanners,
                  onDismiss: _dismissBanner,
                  onRecord: _recordDetectedGame,
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

/// One-click record: a slim row per currently-running, not-yet-configured
/// [popularGamesCatalog] game (see [ClipCoordinator.activeGameIds]),
/// answering the maintainer's ask directly — "the user just needs to open
/// the app and click switch/record, and next time we know". An
/// already-configured game never appears here; the rail's live dot plus
/// auto-follow (`ClipCoordinator._autoSwitchCaptureFor`) already covers it.
/// Rebuilds off [ClipCoordinator.activeGameIds] and [settingsRevision] (a
/// per-game config write elsewhere, e.g. Supported Games' Add, must also
/// make this list disappear).
class _DetectedGameBanners extends StatelessWidget {
  final ClipCoordinator coordinator;
  final List<AppInfo> capturableApps;
  final ValueListenable<int>? settingsRevision;
  final Set<String> dismissed;
  final ValueChanged<String> onDismiss;
  final ValueChanged<CatalogGame> onRecord;

  const _DetectedGameBanners({
    required this.coordinator,
    required this.capturableApps,
    required this.settingsRevision,
    required this.dismissed,
    required this.onDismiss,
    required this.onRecord,
  });

  @override
  Widget build(BuildContext context) {
    final revision = settingsRevision;
    final listenable = Listenable.merge([
      coordinator.activeGameIds,
      if (revision != null) revision,
    ]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final activeIds = coordinator.activeGameIds.value;
        final configuredIds = {
          for (final c in coordinator.settings.allConfigs) c.gameId,
        };
        final candidates = [
          for (final g in popularGamesCatalog)
            if (activeIds.contains(g.gameId) &&
                !configuredIds.contains(g.gameId) &&
                !dismissed.contains(g.gameId))
              g,
        ];
        if (candidates.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final g in candidates)
              _DetectedGameBanner(
                key: ValueKey('detectedGameBanner:${g.gameId}'),
                game: g,
                onDismiss: () => onDismiss(g.gameId),
                onRecord: () => onRecord(g),
              ),
          ],
        );
      },
    );
  }
}

/// A single detected-game row: avatar + "⟨name⟩ is running", a filled
/// Record button, and a dismiss (X) that hides it for this game for the
/// rest of the session — see [_DetectedGameBanners].
class _DetectedGameBanner extends StatelessWidget {
  final CatalogGame game;
  final VoidCallback onDismiss;
  final VoidCallback onRecord;

  const _DetectedGameBanner({
    required this.game,
    required this.onDismiss,
    required this.onRecord,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Container(
      key: ValueKey('detectedGameBannerRow:${game.gameId}'),
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border(bottom: hairlineBorder()),
      ),
      child: Row(
        children: [
          GameTileAvatar(
            gameId: game.gameId,
            displayName: game.displayName,
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${game.displayName} is running',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: theme.textTheme.body,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 28,
            child: FilledButton(
              key: ValueKey('detectedGameBannerRecord:${game.gameId}'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onRecord,
              child: const Text('Record'),
            ),
          ),
          IconButton(
            key: ValueKey('detectedGameBannerDismiss:${game.gameId}'),
            icon: const Icon(Icons.close, size: 16),
            color: tokens.textMuted,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
