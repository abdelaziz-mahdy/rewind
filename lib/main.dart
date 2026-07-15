import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'src/clip/clip_library.dart';
import 'src/clip/clips_dir.dart';
import 'src/clip/match_stats.dart';
import 'src/clip/storage_manager.dart';
import 'src/clip/thumbnail_cache.dart';
import 'src/clip/thumbnail_generator.dart';
import 'src/coordinator/clip_coordinator.dart';
import 'src/events/game_catalog.dart';
import 'src/events/game_registry.dart';
import 'src/events/source_builder.dart';
import 'src/hotkey/hotkey_service.dart';
import 'src/log/file_log.dart';
import 'src/log/log.dart';
import 'src/obs/app_info.dart';
import 'src/obs/capture_engine.dart';
import 'src/obs/display_info.dart';
import 'src/obs/rewind_obs_engine.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/settings_store.dart';
import 'src/tray/tray_service.dart';
import 'src/ui/onboarding_screen.dart';
import 'src/ui/shell.dart';
import 'src/ui/theme.dart';

/// Reveals the clips folder in the OS file manager — shared by the Home
/// AppBar/empty-state buttons and the tray's "Open clips folder" item.
/// Best-effort: no OS handler available (or an unsupported platform) is not
/// fatal, mirroring `ClipTile`'s own `_open`/`_reveal` helpers.
/// gameId → user-facing name for every config carrying a custom
/// [GameConfig.displayName] (apps picked via the capture-source menu).
Map<String, String> _customDisplayNamesOf(AppSettings s) => {
      for (final cfg in s.allConfigs)
        if (cfg.displayName case final name?) cfg.gameId: name,
    };

Future<void> _openClipsFolder(String path) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [path]);
    }
  } catch (_) {
    // Best-effort: no OS handler available is not fatal.
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  // File logging FIRST: everything after this line leaves a crash-proof
  // trail under <support>/logs/ (talker's own history is memory-only).
  startFileLogging(supportDir);
  final store = SettingsStore(supportDir);
  final settings = await store.load();
  // Custom recordings folder (Settings → Storage), falling back to the
  // per-OS default when unset — or when the override can't be created
  // (deleted volume, permissions): losing recordings silently is worse
  // than ignoring a stale preference, so fall back loudly.
  Directory clipsDir;
  try {
    clipsDir = await ensureClipsDir(override: settings.clipsDirPath);
  } catch (err) {
    talker
        .error('Recordings folder "${settings.clipsDirPath}" unusable ($err); '
            'using the default');
    clipsDir = await ensureClipsDir();
  }
  final thumbnailCache = ThumbnailCache(MediaKitThumbnailGenerator());
  final library = await ClipLibrary.load(
    clipsDir,
    onClipDeleted: (clip) => thumbnailCache.invalidate(clip),
  );
  // Per-match kills/deaths (matches.json beside the clips), for the match
  // cards' K/D summaries.
  final matchStats = await MatchStatsStore.load(clipsDir);
  // Best-effort startup sweep for thumbnails orphaned by out-of-app
  // deletions (Finder etc.) — in-app deletes clean up via onClipDeleted.
  unawaited(removeOrphanThumbnails(library.all, clipsDir));

  // Bring up capture. In stub mode init/start succeed but saves write no
  // file (the coordinator ignores those); with libobs linked this starts the
  // real replay buffer. A failed init leaves the app browsable with a banner.
  CaptureEngine? engine = RewindObsEngine();
  String? captureError;
  // Apply the user's saved capture-display choice before init so the shim
  // targets it from the first frame (null: main display). A stale UUID —
  // e.g. an unplugged external monitor — must be dropped, or capture
  // silently records black.
  final connectedDisplays = engine.listDisplays();
  final connectedApps = engine.listCapturableApps();
  final savedDisplay =
      validDisplayUuid(settings.captureDisplayUuid, connectedDisplays);
  if (settings.captureDisplayUuid != null && savedDisplay == null) {
    talker.warning('Saved capture display not found; using main display');
    settings.captureDisplayUuid = null;
    await store.save(settings);
  }
  if (savedDisplay != null) engine.setCaptureDisplay(savedDisplay);
  // Apply a saved capture-app choice before init, mirroring the display
  // pattern above — but, unlike the display case, deliberately WITHOUT
  // stale-validation against `connectedApps`: capturing a specific app is a
  // persistent "always capture this app" preference the user may set
  // before that app is even open, not a piece of hardware that's either
  // connected or not. Per native/shim/README.md ("Application picking"),
  // the shim does NOT fall back to display capture when the bundle id
  // matches no currently-running app — it stays in application-capture
  // mode with a blank feed (logged, not fatal) until a window for that
  // bundle id appears. Clearing the setting here just because the app
  // isn't open yet would silently discard the user's choice every
  // restart, which is worse than a temporary blank feed.
  if (settings.captureAppBundleId != null) {
    engine.setCaptureApp(settings.captureAppBundleId);
  }
  // Audio + quality preferences before init, mirroring the display/app
  // pattern — the shim applies them while building the pipeline.
  engine.setMicEnabled(settings.captureMicrophone);
  engine.setAudioMode(audioModeToShim(settings.audioMode));
  engine.setCaptureQuality(settings.captureFps, settings.captureMaxHeight ?? 0);
  if (!engine.init(
      outDir: clipsDir.path, seconds: settings.defaultBufferSeconds)) {
    captureError = engine.lastError;
    engine.shutdown();
    engine = null;
  } else if (!engine.startBuffer()) {
    captureError = engine.lastError;
  }
  if (captureError != null) {
    talker.error('Capture engine failed to start: $captureError');
  } else {
    talker.info(
        'Capture engine started (buffering ${settings.defaultBufferSeconds}s)');
  }
  final displays = engine != null ? connectedDisplays : const <DisplayInfo>[];
  final capturableApps = engine != null ? connectedApps : const <AppInfo>[];

  // Auto-cleanup: the user's Storage settings drive the retention policy.
  // Enforced after every save (coordinator), once at startup (backlog from
  // sessions where the app wasn't running to see clips age), and on a slow
  // periodic sweep so an age policy fires even across an idle session.
  final storage =
      StorageManager(library, policy: RetentionPolicy.fromSettings(settings));
  Future<void> storageSweep() async {
    final deleted = await storage.enforce();
    if (deleted.isNotEmpty) {
      talker.info('Storage cleanup: removed ${deleted.length} old clip(s)');
    }
  }

  unawaited(storageSweep());
  Timer.periodic(const Duration(minutes: 30), (_) => storageSweep());

  final coordinator = ClipCoordinator(
    registry: GameRegistry(sources: buildSources(settings)),
    library: library,
    storage: storage,
    settings: settings,
    outDir: clipsDir.path,
    engine: engine,
    matchStats: matchStats,
    // Deliberately NO thumbnail generation on save: generating a thumbnail
    // spins up a headless mpv player (real CPU/GPU), and clips are saved
    // WHILE YOU GAME — the worst time to spend that. Thumbnails are made
    // lazily instead, on first view (see `ClipThumbnail`'s FutureBuilder →
    // `ThumbnailCache.ensure`) and cached, so nothing is generated until you
    // actually open a clip list.
  )..start();

  // No startup backfill either, for the same reason — the app must idle at
  // ~0% extra CPU. Missing thumbnails fill in on demand when their clip
  // first scrolls into a view.

  final hotkeys = HotkeyService();
  Future<void> bindBothHotkeys() async {
    final result = await hotkeys.bindAll(
      saveDescriptor: settings.hotkey,
      recordDescriptor: settings.recordHotkey,
      onSave: coordinator.onHotkey,
      onRecordToggle: coordinator.toggleRecording,
    );
    if (!result.saveOk) {
      talker.warning('Could not register hotkey "${settings.hotkey}"');
    } else {
      talker.info('Hotkey "${settings.hotkey}" registered');
    }
    if (!result.recordOk) {
      talker.warning(
          'Could not register record hotkey "${settings.recordHotkey}"');
    } else {
      talker.info('Record hotkey "${settings.recordHotkey}" registered');
    }
  }

  await bindBothHotkeys();

  if (kDebugMode) {
    // Headless save trigger for integration tests (and agent-driven
    // verification): touching <clipsDir>/.save-now behaves like the hotkey.
    // Debug builds only; never active in release.
    final trigger = File('${clipsDir.path}/.save-now');
    // Same idea for the record hotkey: touching <clipsDir>/.record-toggle
    // starts/stops a manual recording headlessly.
    final recordTrigger = File('${clipsDir.path}/.record-toggle');
    Timer.periodic(const Duration(seconds: 1), (_) async {
      if (trigger.existsSync()) {
        try {
          trigger.deleteSync();
        } catch (_) {}
        await coordinator.onHotkey();
      }
      if (recordTrigger.existsSync()) {
        try {
          recordTrigger.deleteSync();
        } catch (_) {}
        await coordinator.toggleRecording();
      }
    });
  }

  // Live buffer state shared by the recorder cluster and the tray toggle.
  final bufferActive =
      ValueNotifier<bool>(engine != null && captureError == null);

  // Bumped at the end of every settings change (see RecorderCluster's
  // settingsRevision doc) so the capture-source line and buffer readout
  // refresh immediately after the user picks something, rather than only on
  // the next unrelated rebuild.
  final settingsRevision = ValueNotifier<int>(0);

  final tray = TrayService();
  await tray.init(
    onSaveClip: coordinator.onHotkey,
    onToggleBuffer: (start) async {
      if (start) {
        bufferActive.value = engine?.startBuffer() ?? false;
      } else {
        engine?.stopBuffer();
        bufferActive.value = false;
      }
    },
    onToggleRecording: coordinator.toggleRecording,
    // No window_manager dependency in v0.1: clicking the tray only offers
    // actions; the window is managed by the OS dock/app switcher.
    onShowWindow: () {},
    onQuit: () async {
      engine?.shutdown();
      await tray.dispose();
      await hotkeys.dispose();
      exit(0);
    },
    onOpenClips: () => _openClipsFolder(clipsDir.path),
  );
  // Seed the tray's toggle labels from the real startup state — its internal
  // defaults assume an active buffer and no recording, which is wrong when
  // capture failed / on every normal cold start respectively.
  await tray.setBufferState(bufferActive.value);
  await tray.setRecordingState(coordinator.isRecording.value);
  // Keep the tray's "Start/Stop recording" label following the deck button
  // and the record hotkey, same as setBufferState above.
  coordinator.isRecording
      .addListener(() => tray.setRecordingState(coordinator.isRecording.value));

  // Make user-picked app names (GameConfig.displayName) resolvable by
  // displayNameFor everywhere gameIds are shown; refreshed on every
  // settings change below.
  registerCustomDisplayNames(_customDisplayNamesOf(settings));

  runApp(RewindApp(
    coordinator: coordinator,
    library: library,
    settings: settings,
    captureError: captureError,
    bufferActive: bufferActive,
    displays: displays,
    capturableApps: capturableApps,
    // `engine` (not the startup snapshot): fresh enumeration every time the
    // source menu opens, so a game launched after Rewind still appears.
    listApps: () => engine?.listCapturableApps() ?? const <AppInfo>[],
    thumbnails: thumbnailCache,
    onOpenClipsFolder: () => _openClipsFolder(clipsDir.path),
    settingsRevision: settingsRevision,
    onSettingsChanged: (s) async {
      await store.save(s);
      // Apply the (possibly per-game) buffer length to the live engine —
      // without this, a default-length edit only takes effect on the next
      // game-activity transition or app restart.
      engine
          ?.setBufferSeconds(s.bufferSecondsFor(coordinator.activeGame.value));
      if (s.captureDisplayUuid != null) {
        engine?.setCaptureDisplay(s.captureDisplayUuid!);
      }
      // Unlike the display line above, this is unconditional: null is a
      // meaningful choice here ("Entire display") that the engine must be
      // told about explicitly to revert out of a previously-set app target.
      engine?.setCaptureApp(s.captureAppBundleId);
      engine?.setMicEnabled(s.captureMicrophone);
      engine?.setAudioMode(audioModeToShim(s.audioMode));
      // Quality stored for next launch (a live pipeline can't change fps/res).
      engine?.setCaptureQuality(s.captureFps, s.captureMaxHeight ?? 0);
      await bindBothHotkeys();
      registerCustomDisplayNames(_customDisplayNamesOf(s));
      // A config added mid-session (picked app, Supported Games' Add) gets
      // its detection watcher NOW — the registry adopts unseen gameIds and
      // the next supervision tick starts them. No restart needed.
      coordinator.registry.addNewSources(buildSources(s));
      // Tightened Storage limits apply immediately, not at the next save.
      storage.policy = RetentionPolicy.fromSettings(s);
      unawaited(storageSweep());
      settingsRevision.value++;
    },
    onSetCaptureApp: (bundleId) => engine?.setCaptureApp(bundleId),
    onHotkeyRecording: (recording) async {
      if (recording) {
        // Suspend BOTH live global hotkeys while the recorder is listening:
        // otherwise pressing a currently-bound combo mid-record both fires
        // a spurious save/toggle and, since the OS owns it at system scope,
        // may never reach the recorder's key handler at all — making it
        // impossible to re-record a hotkey that's already in use (by either
        // field, since a single `hotkey_manager` registry backs both).
        await hotkeys.dispose();
        return;
      }
      // Recording ended WITHOUT a capture (Escape / click away / navigated
      // off Settings): re-bind the still-unchanged settings, restoring
      // what was live before recording started. The successful capture
      // path deliberately does NOT reach here — onSettingsChanged owns
      // that rebind, and a second concurrent unregisterAll+register cycle
      // could interleave into a double registration (one press, two saved
      // clips).
      await bindBothHotkeys();
    },
  ));
}

class RewindApp extends StatefulWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;
  final AppSettings settings;
  final String? captureError;
  final ValueNotifier<bool> bufferActive;
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;
  final List<AppInfo> Function()? listApps;
  final Future<void> Function(AppSettings) onSettingsChanged;
  final Future<void> Function(bool recording) onHotkeyRecording;
  final VoidCallback onOpenClipsFolder;
  final ValueListenable<int>? settingsRevision;
  final void Function(String bundleId)? onSetCaptureApp;
  final ThumbnailCache? thumbnails;

  const RewindApp({
    required this.coordinator,
    required this.library,
    required this.settings,
    required this.captureError,
    required this.bufferActive,
    required this.displays,
    required this.capturableApps,
    this.listApps,
    required this.onSettingsChanged,
    required this.onHotkeyRecording,
    required this.onOpenClipsFolder,
    this.settingsRevision,
    this.onSetCaptureApp,
    this.thumbnails,
    super.key,
  });

  @override
  State<RewindApp> createState() => _RewindAppState();
}

class _RewindAppState extends State<RewindApp> {
  late bool _showOnboarding = !widget.settings.onboardingComplete;

  Future<void> _completeOnboarding() async {
    widget.settings.onboardingComplete = true;
    await widget.onSettingsChanged(widget.settings);
    if (mounted) setState(() => _showOnboarding = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rewind',
      theme: rewindTheme(),
      home: _showOnboarding
          ? OnboardingScreen(
              settings: widget.settings,
              onChanged: widget.onSettingsChanged,
              onDone: _completeOnboarding,
            )
          : Shell(
              coordinator: widget.coordinator,
              library: widget.library,
              captureError: widget.captureError,
              bufferActive: widget.bufferActive,
              hotkeyLabel: widget.settings.hotkey,
              displays: widget.displays,
              capturableApps: widget.capturableApps,
              listApps: widget.listApps,
              onSettingsChanged: widget.onSettingsChanged,
              onOpenClipsFolder: widget.onOpenClipsFolder,
              settingsRevision: widget.settingsRevision,
              onHotkeyRecording: widget.onHotkeyRecording,
              onSetCaptureApp: widget.onSetCaptureApp,
              thumbnails: widget.thumbnails,
            ),
    );
  }
}
