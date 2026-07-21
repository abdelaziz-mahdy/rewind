import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'logs_screen.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/thumbnail_cache.dart';
import '../coordinator/clip_coordinator.dart';
import '../events/game_catalog.dart';
import '../games/exe_icon_resolver.dart';
import '../games/league/ddragon.dart';
import '../games/steam_icon_resolver.dart';
import '../obs/app_info.dart';
import '../obs/audio_input_info.dart';
import '../obs/display_info.dart';
import '../settings/app_settings.dart';
import 'all_clips_screen.dart';
import 'capture_app_match.dart';
import 'game_directory.dart';
import 'game_hub_screen.dart';
import 'settings_screen.dart';
import 'shell_destination.dart';
import 'supported_games_screen.dart';
import 'system_settings.dart';
import 'theme.dart';
import 'widgets/game_tile_avatar.dart';
import 'widgets/nav_rail.dart';

/// The app's persistent scaffold (§3.1): a 220 px left rail — ending in the
/// `RecorderCluster`, a Discord-style Save/Record/status block pinned to its
/// bottom — beside a content area that swaps on a sealed [ShellDestination]
/// — plain `StatefulWidget` navigation, no router package. The old full-
/// width top deck (`StatusStrip`) is gone per maintainer feedback ("feels
/// redundant"); its permission [_ErrorBanner] now renders at the top of the
/// content area instead. Owns the save-error SnackBar listener (moved here
/// from the old `HomeScreen` so it fires on every destination, not just All
/// Clips).
class Shell extends StatefulWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;
  final String? captureError;

  /// Forwarded to every [ClipTile] (via All Clips / each game hub) for
  /// leading-tile thumbnails. Null (e.g. every existing Shell test) always
  /// renders ClipTile's placeholder.
  final ThumbnailCache? thumbnails;

  /// Forwarded to each game hub for match-card/detail champion+item art.
  /// Null (e.g. every existing Shell test) always renders the monogram/
  /// blank fallbacks.
  final DDragon? ddragon;

  /// Live buffer state (toggled by the tray's pause/resume). When null the
  /// deck assumes the buffer is running iff capture came up without error.
  final ValueListenable<bool>? bufferActive;

  /// See `RecorderCluster.bufferAutoPaused`'s doc.
  final ValueListenable<bool>? bufferAutoPaused;
  final String hotkeyLabel;

  /// Connected displays / capturable apps, forwarded to the status strip's
  /// capture-source chip and the embedded Settings destination.
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;

  /// Audio INPUT devices (microphones), forwarded to the embedded Settings
  /// destination's "Microphone" sub-row — hidden entirely when empty (see
  /// `SettingsScreen.audioInputs`).
  final List<AudioInputInfo> audioInputs;

  /// Live app enumeration, forwarded to the rail's recorder cluster so the
  /// capture-source menu re-lists on every open (see `RecorderCluster.
  /// listApps`).
  final List<AppInfo> Function()? listApps;

  /// Persists a settings change (mutated in place) — used by the
  /// capture-source chip, the buffer quick-set, and embedded Settings.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Reveals the clips folder in the OS file manager — wired to All Clips'
  /// header button and its empty-state button.
  final VoidCallback onOpenClipsFolder;

  /// Forwarded to [NavRail] — both its game list and its embedded
  /// `RecorderCluster` must refresh after an in-place settings mutation,
  /// e.g. a per-game buffer edit. Optional — see `RecorderCluster.
  /// settingsRevision`'s doc.
  final ValueListenable<int>? settingsRevision;

  /// Forwarded to the embedded Settings destination's hotkey recorder.
  final Future<void> Function(bool recording)? onHotkeyRecording;

  /// Forwarded to the embedded Settings destination's Storage tab — runs
  /// retention enforcement now and returns the removed clips (see
  /// `SettingsScreen.onCleanUpStorage`).
  final Future<List<Clip>> Function()? onCleanUpStorage;

  /// Points the live capture engine at a specific app, identified by
  /// [AppInfo.bundleId] — used by the detected-game banner's Record button
  /// to start capturing a game the moment it's confirmed, mirroring
  /// [ClipCoordinator]'s own "follow the game" auto-switch but triggered
  /// explicitly by the user's click rather than a background detection
  /// event. Does not persist [AppSettings.captureAppBundleId]; null when no
  /// capture backend is wired up (dev mode).
  final void Function(String bundleId)? onSetCaptureApp;

  /// Forwarded to the embedded Settings destination's mic-volume "listen"
  /// button (see `SettingsScreen.onSetMicMonitoring`).
  final void Function(bool enabled)? onSetMicMonitoring;

  /// Forwarded to the Settings destination's mic-test meter (see
  /// `SettingsScreen.audioLevels`).
  final String? Function()? audioLevels;

  /// Resolves the live `SteamStatsWatcher.status` notifier for the embedded
  /// Settings destination's Steam page — a GETTER, not the notifier itself,
  /// re-read every time Settings builds (a keyless watcher exists
  /// unconditionally, see `source_builder.dart`, so this is really about
  /// picking up `main.dart`'s registry lookup consistently, not about
  /// waiting for one to appear). Null (e.g. every existing Shell test that
  /// doesn't wire it) shows Settings' plain idle line instead of a live one.
  final ValueListenable<String?>? Function()? steamStatus;

  /// Seeds the Shell's starting destination -- used by onboarding's "Set up
  /// Steam achievements" shortcut, which finishes onboarding straight into
  /// `SettingsDestination(initialTab: 'Steam')` instead of the usual
  /// AllClipsDestination default. Null (every other launch path) keeps
  /// today's behavior.
  final ShellDestination? initialDestination;

  /// Resolves real game icons/names from the local Steam library for the
  /// Supported Games "Running now" list and the home detected-game banners
  /// (Steam/Wine games have no macOS bundle icon). Null in tests / no Steam.
  final SteamIconResolver? steamResolver;

  /// Fallback for a non-Steam Wine game: its icon read from its own `.exe`.
  final ExeIconResolver? exeResolver;

  const Shell({
    required this.coordinator,
    required this.library,
    this.captureError,
    this.bufferActive,
    this.bufferAutoPaused,
    required this.hotkeyLabel,
    this.displays = const [],
    this.capturableApps = const [],
    this.audioInputs = const [],
    this.listApps,
    required this.onSettingsChanged,
    required this.onOpenClipsFolder,
    this.settingsRevision,
    this.onHotkeyRecording,
    this.onCleanUpStorage,
    this.onSetCaptureApp,
    this.onSetMicMonitoring,
    this.audioLevels,
    this.thumbnails,
    this.ddragon,
    this.steamStatus,
    this.initialDestination,
    this.steamResolver,
    this.exeResolver,
    super.key,
  });

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late ShellDestination _destination =
      widget.initialDestination ?? const AllClipsDestination();

  /// The destination showing right before Settings was opened — where the
  /// full-page Settings screen's ✕ button returns to. Updated only on the
  /// transition INTO Settings (not while already there), so navigating the
  /// Settings sidebar itself never overwrites it.
  ShellDestination _beforeSettings = const AllClipsDestination();

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

  /// The Steam-detected banner's Record button: learns the running [app] as a
  /// game (storing the resolved Steam [art]'s icon + name, see
  /// `learnAppAsGame`), then opens its hub. Unlike [_recordDetectedGame] it
  /// does NOT force the capture target for a bundle-less Wine game
  /// (`bundleId == ''` must never reach `setCaptureApp`, per `AppInfo`) — now
  /// that the game is configured, the coordinator's auto-switch targets its
  /// window on its own. A real bundled app is still pointed at immediately.
  void _recordDetectedApp(AppInfo app, SteamGameArt? art) {
    final settings = widget.coordinator.settings;
    final gameId = learnAppAsGame(settings, app, art: art);
    widget.onSettingsChanged(settings);
    if (app.bundleId.isNotEmpty) widget.onSetCaptureApp?.call(app.bundleId);
    _select(GameDestination(gameId));
  }

  @override
  void initState() {
    super.initState();
    widget.coordinator.lastSaveError.addListener(_showSaveErrorIfAny);
    widget.coordinator.lastManualSave.addListener(_showManualSaveToast);
  }

  @override
  void dispose() {
    widget.coordinator.lastSaveError.removeListener(_showSaveErrorIfAny);
    widget.coordinator.lastManualSave.removeListener(_showManualSaveToast);
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

  /// Visible confirmation for a manual save — without it, pressing "Save
  /// clip" from Settings or an empty hub looked like it did nothing (the
  /// only success signals were an optional sound and a clip list the user
  /// might not be on).
  void _showManualSaveToast() {
    if (!mounted) return;
    final clip = widget.coordinator.lastManualSave.value;
    if (clip == null) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 3),
      content: Text('Clip saved'),
    ));
  }

  void _select(ShellDestination destination) => setState(() {
        if (destination is SettingsDestination &&
            _destination is! SettingsDestination) {
          _beforeSettings = _destination;
        }
        _destination = destination;
      });

  /// Settings' ✕ button: back to whatever was showing before Settings was
  /// opened (All Clips by default, if the app launched straight into it).
  void _closeSettings() => _select(_beforeSettings);

  void _openLogs() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => const LogsScreen(),
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
          thumbnails: widget.thumbnails,
          matchStats: widget.coordinator.matchStats,
          ddragon: widget.ddragon,
        ),
      GameDestination(gameId: final id) => GameHubScreen(
          key: ValueKey('gameHubScreen:$id'),
          gameId: id,
          library: widget.library,
          coordinator: widget.coordinator,
          hotkeyLabel: widget.hotkeyLabel,
          onSettingsChanged: widget.onSettingsChanged,
          onEditCaptureSettings: () =>
              _select(SettingsDestination(initialGameId: id)),
          settingsRevision: widget.settingsRevision,
          thumbnails: widget.thumbnails,
          ddragon: widget.ddragon,
        ),
      SupportedGamesDestination() => SupportedGamesScreen(
          key: const ValueKey('supportedGamesScreen'),
          coordinator: widget.coordinator,
          library: widget.library,
          onSettingsChanged: widget.onSettingsChanged,
          onOpenGame: (gameId) => _select(GameDestination(gameId)),
          listApps: widget.listApps,
          steamResolver: widget.steamResolver,
          exeResolver: widget.exeResolver,
        ),
      SettingsDestination(initialGameId: final gameId, initialTab: final tab) =>
        SettingsScreen(
          key: const ValueKey('settingsScreen'),
          settings: widget.coordinator.settings,
          onChanged: widget.onSettingsChanged,
          displays: widget.displays,
          capturableApps: widget.capturableApps,
          audioInputs: widget.audioInputs,
          onSetMicMonitoring: widget.onSetMicMonitoring,
          audioLevels: widget.audioLevels,
          onHotkeyRecording: widget.onHotkeyRecording,
          library: widget.library,
          onCleanUpStorage: widget.onCleanUpStorage,
          onClose: _closeSettings,
          initialGameId: gameId,
          initialTab: tab,
          // Same derivation as the rail (`nav_rail.dart`'s `_buildRail`) so
          // the MY GAMES sidebar section never disagrees with it on naming,
          // icons, or ordering.
          gameEntries: buildGameDirectory(
            settings: widget.coordinator.settings,
            clips: widget.library.all,
            activeIds: widget.coordinator.activeGameIds.value,
          ),
          steamStatus: widget.steamStatus?.call(),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    // Settings is full-page: it covers the whole window with its own
    // sidebar as the ONLY nav while open, so the app rail (and the error/
    // detected-game banners that sit above the normal content area) are not
    // shown at all — same rule a full-screen route would follow, just
    // without an actual Navigator push.
    if (_destination is SettingsDestination) {
      return _content(context);
    }
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
            captureError: widget.captureError,
            bufferActive: widget.bufferActive,
            bufferAutoPaused: widget.bufferAutoPaused,
            displays: widget.displays,
            capturableApps: widget.capturableApps,
            listApps: widget.listApps,
            onSettingsChanged: widget.onSettingsChanged,
            onOpenSettings: () => _select(const SettingsDestination()),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.captureError != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: _ErrorBanner(message: widget.captureError!),
                  ),
                _DetectedGameBanners(
                  coordinator: widget.coordinator,
                  capturableApps: widget.capturableApps,
                  settingsRevision: widget.settingsRevision,
                  dismissed: _dismissedBanners,
                  onDismiss: _dismissBanner,
                  onRecord: _recordDetectedGame,
                  listApps: widget.listApps,
                  steamResolver: widget.steamResolver,
                  onRecordApp: _recordDetectedApp,
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
/// A "⟨game⟩ is running — Record?" suggestion, from either of two sources:
/// a catalog game Rewind detected in [ClipCoordinator.activeGameIds], or a
/// running app confirmed to be an installed Steam game (see
/// [SteamIconResolver.steamGameByInstallDir]). The Steam source is what lets
/// a game Rewind doesn't ship a catalog entry for — R.E.P.O. via CrossOver —
/// surface here at all: "is this a game?" is answered by Steam's own
/// installed-games list, not the noisy "bundle-less app = probably a game"
/// guess (which would suggest explorer.exe / steamwebhelper).
class _Suggestion {
  final String gameId;
  final String displayName;
  final String? iconPath;
  final VoidCallback onRecord;

  const _Suggestion({
    required this.gameId,
    required this.displayName,
    required this.iconPath,
    required this.onRecord,
  });
}

/// Rebuilds off [ClipCoordinator.activeGameIds] and [settingsRevision] (a
/// per-game config write elsewhere, e.g. Supported Games' Add, must also
/// make this list disappear). When a [steamResolver] + [listApps] are wired,
/// also polls the running-app list on a low cadence — a Steam game that
/// isn't a registered detection source (so it never enters `activeGameIds`)
/// otherwise wouldn't trigger a rebuild when it launches.
class _DetectedGameBanners extends StatefulWidget {
  final ClipCoordinator coordinator;
  final List<AppInfo> capturableApps;
  final ValueListenable<int>? settingsRevision;
  final Set<String> dismissed;
  final ValueChanged<String> onDismiss;
  final ValueChanged<CatalogGame> onRecord;
  final List<AppInfo> Function()? listApps;
  final SteamIconResolver? steamResolver;
  final void Function(AppInfo app, SteamGameArt? art) onRecordApp;

  const _DetectedGameBanners({
    required this.coordinator,
    required this.capturableApps,
    required this.settingsRevision,
    required this.dismissed,
    required this.onDismiss,
    required this.onRecord,
    required this.listApps,
    required this.steamResolver,
    required this.onRecordApp,
  });

  @override
  State<_DetectedGameBanners> createState() => _DetectedGameBannersState();
}

class _DetectedGameBannersState extends State<_DetectedGameBanners> {
  /// At most this many suggestions at once, so a machine with several games
  /// open doesn't bury the home screen under a stack of banners.
  static const _maxBanners = 3;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Only poll when there's a Steam source to discover non-registered games
    // with — every existing Shell test wires neither, so no timer starts and
    // none of them hang on a perpetual poll.
    if (widget.steamResolver != null && widget.listApps != null) {
      _poll = Timer.periodic(const Duration(seconds: 4), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Running apps that Steam confirms are installed games, not yet configured
  /// or dismissed — the trustworthy half of the suggestions.
  List<_Suggestion> _steamSuggestions(Set<String> configuredIds) {
    final resolver = widget.steamResolver;
    final apps = widget.listApps;
    if (resolver == null || apps == null) return const [];
    final out = <_Suggestion>[];
    for (final app in apps()) {
      final game = resolver.steamGameByInstallDir(app.name);
      if (game == null) continue; // Not an installed Steam game — skip.
      final gameId = gameIdForApp(app);
      if (configuredIds.contains(gameId) || widget.dismissed.contains(gameId)) {
        continue;
      }
      final art = resolver.resolveByInstallDir(app.name);
      out.add(_Suggestion(
        gameId: gameId,
        displayName: game.name,
        iconPath: art?.iconPath,
        onRecord: () => widget.onRecordApp(app, art),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final revision = widget.settingsRevision;
    final listenable = Listenable.merge([
      widget.coordinator.activeGameIds,
      if (revision != null) revision,
    ]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final activeIds = widget.coordinator.activeGameIds.value;
        final configuredIds = {
          for (final c in widget.coordinator.settings.allConfigs) c.gameId,
        };
        final seen = <String>{};
        final suggestions = <_Suggestion>[];
        for (final g in popularGamesCatalog) {
          if (activeIds.contains(g.gameId) &&
              !configuredIds.contains(g.gameId) &&
              !widget.dismissed.contains(g.gameId) &&
              seen.add(g.gameId)) {
            suggestions.add(_Suggestion(
              gameId: g.gameId,
              displayName: g.displayName,
              iconPath: null,
              onRecord: () => widget.onRecord(g),
            ));
          }
        }
        for (final s in _steamSuggestions(configuredIds)) {
          if (seen.add(s.gameId)) suggestions.add(s);
        }
        if (suggestions.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in suggestions.take(_maxBanners))
              _DetectedGameBanner(
                key: ValueKey('detectedGameBanner:${s.gameId}'),
                gameId: s.gameId,
                displayName: s.displayName,
                iconPath: s.iconPath,
                onDismiss: () => widget.onDismiss(s.gameId),
                onRecord: s.onRecord,
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
  final String gameId;
  final String displayName;
  final String? iconPath;
  final VoidCallback onDismiss;
  final VoidCallback onRecord;

  const _DetectedGameBanner({
    required this.gameId,
    required this.displayName,
    required this.iconPath,
    required this.onDismiss,
    required this.onRecord,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Container(
      key: ValueKey('detectedGameBannerRow:$gameId'),
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border(bottom: hairlineBorder()),
      ),
      child: Row(
        children: [
          GameTileAvatar(
            gameId: gameId,
            displayName: displayName,
            iconPath: iconPath,
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$displayName is running',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: theme.textTheme.body,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 28,
            child: FilledButton(
              key: ValueKey('detectedGameBannerRecord:$gameId'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onRecord,
              // "Add game", not "Record": the action learns the game so
              // Rewind auto-captures it (capture then follows) — it does not
              // start a one-off recording.
              child: const Text('Add game'),
            ),
          ),
          IconButton(
            key: ValueKey('detectedGameBannerDismiss:$gameId'),
            icon: const Icon(Icons.close, size: 16),
            color: tokens.textMuted,
            // Names the scope: dismissal is session-only, the banner comes
            // back next launch/game — without this the icon-only ✕ can read
            // as "never show again".
            tooltip: 'Dismiss for now',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// The permission/capture-error banner, moved here (verbatim) from the old
/// `StatusStrip` deck: it now renders at the top of the content area,
/// full width, above the detected-game banners, instead of as a second row
/// under the old top deck.
class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  bool get _isPermissionError =>
      Platform.isMacOS && message.toLowerCase().contains('permission');

  static Future<void> _openScreenRecordingSettings() =>
      openScreenRecordingSettings();

  @override
  Widget build(BuildContext context) {
    final amber = context.rewindTokens.warn;
    // Only coach the user toward the permission pane when the failure is
    // actually about permission — the shim reports that case explicitly.
    // Any other error must stand on its own instead of misdirecting.
    final text = Platform.isMacOS &&
            message.toLowerCase().contains('permission') &&
            !message.contains('System Settings')
        ? '$message\nSystem Settings → Privacy & Security → Screen Recording'
        : message;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(context.rewindTokens.radiusCard),
        border: Border.all(color: amber),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: amber),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: Theme.of(context).textTheme.body),
                if (_isPermissionError) ...[
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _openScreenRecordingSettings,
                      child: Text('Open Screen Recording Settings'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
