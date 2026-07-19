import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/clip/clip.dart';
import 'src/clip/clip_library.dart';
import 'src/clip/clips_dir.dart';
import 'src/clip/match_stats.dart';
import 'src/clip/storage_manager.dart';
import 'src/clip/thumbnail_cache.dart';
import 'src/clip/thumbnail_generator.dart';
import 'src/coordinator/buffer_policy.dart';
import 'src/coordinator/clip_coordinator.dart';
import 'src/events/game_catalog.dart';
import 'src/events/game_registry.dart';
import 'src/events/source_builder.dart';
import 'src/events/steam_stats_watcher.dart';
import 'src/games/league/ddragon.dart';
import 'src/hotkey/hotkey_service.dart';
import 'src/log/file_log.dart';
import 'src/log/log.dart';
import 'src/log/perf_monitor.dart';
import 'src/obs/app_info.dart';
import 'src/obs/audio_input_info.dart';
import 'src/obs/buffer_transition.dart';
import 'src/obs/capture_engine.dart';
import 'src/obs/display_info.dart';
import 'src/obs/rewind_obs_engine.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/settings_store.dart';
import 'src/sound/clip_sounds.dart';
import 'src/tray/tray_service.dart';
import 'src/ui/onboarding_screen.dart';
import 'src/ui/shell.dart';
import 'src/ui/shell_destination.dart';
import 'src/ui/theme.dart';

/// Reveals the clips folder in the OS file manager — shared by the Home
/// AppBar/empty-state buttons and the tray's "Open clips folder" item.
/// Best-effort: no OS handler available (or an unsupported platform) is not
/// fatal, mirroring `ClipTile`'s own `_open`/`_reveal` helpers.
/// gameId → user-facing name for every config carrying a non-blank custom
/// [GameConfig.displayName] — either a picked app's real-cased name (the
/// capture-source menu) or a user's explicit rename of a game (Task 28,
/// `settings_screen.dart`'s `gameNameField`). `displayNameFor` itself
/// further refuses to honor an entry here for a descriptor-registered game
/// (see `isGameRenameable`'s doc), so this stays a plain "every override on
/// record" projection rather than duplicating that precedence check.
Map<String, String> _customDisplayNamesOf(AppSettings s) => {
      for (final cfg in s.allConfigs)
        if (cfg.displayName?.trim() case final name? when name.isNotEmpty)
          cfg.gameId: name,
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

/// Relaunches the running macOS app: spawns a fresh instance (`open -n
/// <bundle>.app`), then exits this one. Onboarding's permission step offers
/// this once Screen Recording is granted mid-session — per CLAUDE.md's TCC
/// gotchas, a grant only takes effect for a NEW process, so continuing to
/// run this one would keep capturing black. No-op on non-macOS (no
/// equivalent permission-on-relaunch gate).
Future<void> _relaunch() async {
  if (!Platform.isMacOS) return;
  try {
    // Platform.resolvedExecutable for a bundled app is
    // "<bundle>.app/Contents/MacOS/<exe>" — three directories up from the
    // executable is the bundle root `open` expects.
    final exeDir = p.dirname(Platform.resolvedExecutable); // .../MacOS
    final bundlePath = p.dirname(p.dirname(exeDir)); // .../<name>.app
    await Process.start('open', ['-n', bundlePath],
        mode: ProcessStartMode.detached);
  } catch (err) {
    talker.warning('Relaunch failed: $err');
    return; // don't exit without a replacement instance under way
  }
  exit(0);
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
  // Champion/item art (Data Dragon, Riot's public static-asset CDN — see
  // docs/COMPLIANCE.md), cached under a `.ddragon/` dir beside the clips so
  // a match in progress never pays a network cost.
  final ddragon = DDragon(cacheDir: Directory('${clipsDir.path}/.ddragon'));
  // Best-effort startup sweep for thumbnails orphaned by out-of-app
  // deletions (Finder etc.) — in-app deletes clean up via onClipDeleted.
  unawaited(removeOrphanThumbnails(library.all, clipsDir));

  // Bring up capture. In stub mode init/start succeed but saves write no
  // file (the coordinator ignores those); with libobs linked this starts the
  // real replay buffer. A failed init leaves the app browsable with a banner.
  CaptureEngine? engine = RewindObsEngine();
  String? captureError;
  // Apply the user's saved capture-display choice before init so the shim
  // targets it from the first frame (null: main display). A genuinely stale
  // UUID — an external monitor that's now UNPLUGGED — must be dropped, or
  // capture silently records black. But an EMPTY enumeration is NOT proof of
  // that (see validDisplayUuid): it keeps the choice, so we only wipe when
  // the display list came back non-empty AND lacks the UUID. Wiping on an
  // empty list would erase a deliberate "record my other monitor" choice and
  // fall capture back to the main display — recording the WRONG screen.
  final connectedDisplays = engine.listDisplays();
  final connectedApps = engine.listCapturableApps();
  final connectedAudioInputs = engine.listAudioInputs();
  final savedDisplay =
      validDisplayUuid(settings.captureDisplayUuid, connectedDisplays);
  if (settings.captureDisplayUuid != null && savedDisplay == null) {
    talker.warning('Saved capture display no longer connected; using main '
        'display');
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
  engine.setMicDevice(settings.micDeviceUid);
  engine.setMicVolume(settings.micVolume);
  engine.setMicLeveling(settings.micAutoLevel);
  engine.setAudioMode(audioModeToShim(settings.audioMode));
  engine.setGameVolume(settings.gameAudioVolume);
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
  final audioInputs =
      engine != null ? connectedAudioInputs : const <AudioInputInfo>[];

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
    sounds: SystemClipSounds(),
    // Deliberately NO thumbnail generation on save: generating a thumbnail
    // spins up a headless mpv player (real CPU/GPU), and clips are saved
    // WHILE YOU GAME — the worst time to spend that. Thumbnails are made
    // lazily instead, on first view (see `ClipThumbnail`'s FutureBuilder →
    // `ThumbnailCache.ensure`) and cached, so nothing is generated until you
    // actually open a clip list.
  )..start();

  // SteamStatsWatcher never "activates" through GameRegistry's normal tick
  // (see its isGameRunning doc), so nothing else ever calls its start() —
  // and it has no reference to `coordinator` at construction time
  // (buildSources runs before the coordinator exists) to resolve the
  // currently-active game for attribution. Both are wired here. Unlike the
  // credential-gated watcher this replaces, `source_builder.dart` now
  // constructs it UNCONDITIONALLY, so this only ever needs to run once at
  // startup — no "credentials added mid-session" case to re-run it for —
  // but it's still idempotent (start() itself no-ops on an
  // already-running watcher) so calling it again would be harmless if that
  // ever changes.
  void wireSteamWatchers() {
    for (final s
        in coordinator.registry.sources.whereType<SteamStatsWatcher>()) {
      s.resolveGameId = () => coordinator.activeGame.value;
      unawaited(s.start());
    }
  }

  wireSteamWatchers();
  // The Steam status line in Settings — reflects whatever the (always-
  // present) watcher's own discovery/toggle state currently is; see
  // `SteamStatsWatcher`'s doc for its status strings. `RewindApp`/`Shell`
  // re-read this getter each time Settings builds.
  ValueNotifier<String?>? steamStatus() => coordinator.registry.sources
      .whereType<SteamStatsWatcher>()
      .firstOrNull
      ?.status;

  // No startup backfill either, for the same reason — the app must idle at
  // ~0% extra CPU. Missing thumbnails fill in on demand when their clip
  // first scrolls into a view.

  // Always-on perf telemetry: one C call + one small JSONL append every
  // 10s (see PerfMonitor's own doc) — negligible overhead, but the
  // lagged/skipped-frame counters it samples are the signal that tells us
  // whether capture itself is straining the machine (vs. e.g. the game
  // simply being CPU-bound), which a user report alone can't distinguish.
  // Never disposed: it's meant to run for the app's whole lifetime, same as
  // the tray/hotkey services below.
  PerfMonitor(
    engine: engine,
    activeGameGetter: () => coordinator.activeGame.value,
    logsDir: Directory(p.join(supportDir.path, 'logs')),
  ).start();

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

  // True while a STOPPED buffer is paused BY THE captureOnlyInGame POLICY
  // (as opposed to a manual tray pause) — see applyBufferPolicy below and
  // RecorderCluster.bufferAutoPaused's doc.
  final bufferAutoPaused = ValueNotifier<bool>(false);

  // Bumped at the end of every settings change (see RecorderCluster's
  // settingsRevision doc) so the capture-source line and buffer readout
  // refresh immediately after the user picks something, rather than only on
  // the next unrelated rebuild.
  final settingsRevision = ValueNotifier<int>(0);

  final tray = TrayService();

  // Whether the first-run (or Settings-reopened, first-run-only) onboarding
  // guide is currently the visible screen. Seeded from the same source
  // `_RewindAppState._showOnboarding` uses, so the very first
  // `applyBufferPolicy` call below already accounts for it; flipped back to
  // false by `_RewindAppState._completeOnboarding` when onboarding finishes
  // or is skipped. Consulted (NOT threaded into buffer_policy.dart's pure
  // functions — those stay setting-only) so onboarding's "Try it now" step
  // can still save a clip at the desktop even though `captureOnlyInGame`
  // defaults to true: see [applyBufferPolicy]'s `captureOnlyInGame` input
  // below.
  final onboardingActive = ValueNotifier<bool>(!settings.onboardingComplete);

  // ---- "Only record while playing" (AppSettings.captureOnlyInGame) ----
  //
  // [applyBufferPolicy] is the SINGLE control point every buffer start/stop
  // decision flows through — the auto-pause policy, the tray's manual
  // Pause/Resume, and startup all funnel through it so they can't fight or
  // desync. It's re-run on: coordinator.playingGameIds changing (a game
  // transition), the setting changing (onSettingsChanged below), the tray
  // toggle, onboardingActive changing, and once at startup.
  //
  // Reads playingGameIds, NOT activeGameIds: a game whose detection only
  // means "the launcher/client is open" (e.g. League's catalog entry) must
  // not resume the buffer — see ClipCoordinator.playingGameIds' doc.
  // activeGameIds stays the input for everything else (rail dots, Supported
  // Games, auto-switch, session stamping), which all still want to see the
  // client.
  //
  // [manualOverride] is the tray's Pause/Resume override; see
  // buffer_policy.dart's doc for the exact precedence rule: a manual Pause
  // always wins (sticky until an explicit Resume), while a manual Resume
  // only forces the buffer on TEMPORARILY — it's cleared at the very next
  // game transition, handing control back to the policy.
  BufferManualOverride manualOverride;
  void applyBufferPolicy() {
    final anyGameActive = coordinator.playingGameIds.value.isNotEmpty;
    // While onboarding is on screen, behave as if the setting were off —
    // `settings.captureOnlyInGame` itself is left untouched (it's still
    // what Settings shows/persists).
    final effectiveCaptureOnlyInGame =
        settings.captureOnlyInGame && !onboardingActive.value;
    final desired = desiredBufferActive(
      captureOnlyInGame: effectiveCaptureOnlyInGame,
      anyGameActive: anyGameActive,
      manualOverride: manualOverride,
    );
    if (desired != bufferActive.value) {
      // See buffer_transition.dart's doc: suspends/resumes the capture
      // session around the buffer stop/start so a paused buffer holds no
      // live capture source (screen-recording indicator, DRM-blanked video,
      // idle GPU/CPU cost — see CHANGELOG).
      bufferActive.value = applyBufferTransition(engine, desired: desired);
    }
    bufferAutoPaused.value = isAutoPaused(
      captureOnlyInGame: effectiveCaptureOnlyInGame,
      anyGameActive: anyGameActive,
      manualOverride: manualOverride,
    );
    unawaited(tray.setBufferState(bufferActive.value));
  }

  await tray.init(
    onSaveClip: coordinator.onHotkey,
    onToggleBuffer: (start) async {
      manualOverride = start;
      applyBufferPolicy();
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
  // A game transition (activation OR deactivation) always re-evaluates the
  // policy from scratch: clears a temporary Resume override so
  // captureOnlyInGame can reclaim control, but leaves a manual Pause
  // sticky — see buffer_policy.dart's clearedOverrideAfterTransition doc.
  // Keyed off playingGameIds (the SAME notifier applyBufferPolicy reads
  // above) rather than activeGameIds, so a client-only activation — which
  // never touches the buffer — doesn't clear a manual override either.
  coordinator.playingGameIds.addListener(() {
    manualOverride = clearedOverrideAfterTransition(manualOverride);
    applyBufferPolicy();
  });
  // Onboarding finishing (or being skipped) is itself a policy input change
  // — re-run immediately so the deck flips straight to "Waiting for a game"
  // (no restart needed) instead of waiting for the next unrelated game
  // transition.
  onboardingActive.addListener(applyBufferPolicy);
  // Startup pass: seeds the tray's buffer label from the real state (its
  // internal default assumes an active buffer, wrong when capture failed)
  // AND applies the policy's own verdict — e.g. captureOnlyInGame ON with
  // no game detected yet immediately stops the buffer the init call above
  // just started, rather than idling it until the first game transition.
  applyBufferPolicy();
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
    bufferAutoPaused: bufferAutoPaused,
    displays: displays,
    capturableApps: capturableApps,
    audioInputs: audioInputs,
    // `engine` (not the startup snapshot): fresh enumeration every time the
    // source menu opens, so a game launched after Rewind still appears.
    listApps: () => engine?.listCapturableApps() ?? const <AppInfo>[],
    engine: engine,
    onboardingActive: onboardingActive,
    onRelaunch: () => unawaited(_relaunch()),
    thumbnails: thumbnailCache,
    ddragon: ddragon,
    onOpenClipsFolder: () => _openClipsFolder(clipsDir.path),
    settingsRevision: settingsRevision,
    steamStatus: steamStatus,
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
      engine?.setMicDevice(s.micDeviceUid);
      engine?.setMicVolume(s.micVolume);
      engine?.setMicLeveling(s.micAutoLevel);
      engine?.setAudioMode(audioModeToShim(s.audioMode));
      engine?.setGameVolume(s.gameAudioVolume);
      // Quality stored for next launch (a live pipeline can't change fps/res).
      engine?.setCaptureQuality(s.captureFps, s.captureMaxHeight ?? 0);
      await bindBothHotkeys();
      registerCustomDisplayNames(_customDisplayNamesOf(s));
      // A config added mid-session (picked app, Supported Games' Add) gets
      // its detection watcher NOW — the registry adopts unseen gameIds and
      // the next supervision tick starts them. No restart needed.
      coordinator.registry.addNewSources(buildSources(s));
      // addNewSources dedupes by gameId, so this never creates a second
      // 'steam' source — re-running wireSteamWatchers here is a no-op
      // (start() is idempotent) kept only for symmetry with the other
      // settings-driven re-wiring above/below.
      wireSteamWatchers();
      // Tightened Storage limits apply immediately, not at the next save.
      storage.policy = RetentionPolicy.fromSettings(s);
      unawaited(storageSweep());
      // Re-run the buffer policy in case captureOnlyInGame itself just
      // changed (or to no-op harmlessly otherwise) — see applyBufferPolicy's
      // doc, the single control point this must flow through.
      applyBufferPolicy();
      settingsRevision.value++;
    },
    onSetCaptureApp: (bundleId) => engine?.setCaptureApp(bundleId),
    onSetMicMonitoring: (enabled) => engine?.setMicMonitoring(enabled),
    onCleanUpStorage: () async {
      // Same enforcement as the automatic sweep, but user-triggered from
      // Settings → Storage; returns the removals so the tab can report
      // "Removed N clips · freed X" instead of a silent background log line.
      final deleted = await storage.enforce();
      if (deleted.isNotEmpty) {
        talker.info('Manual storage cleanup: removed ${deleted.length} '
            'clip(s)');
      }
      return deleted;
    },
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

  /// See `RecorderCluster.bufferAutoPaused`'s doc — forwarded straight
  /// through to `Shell`.
  final ValueListenable<bool>? bufferAutoPaused;
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;
  final List<AudioInputInfo> audioInputs;
  final List<AppInfo> Function()? listApps;
  final Future<void> Function(AppSettings) onSettingsChanged;
  final Future<void> Function(bool recording) onHotkeyRecording;
  final VoidCallback onOpenClipsFolder;
  final ValueListenable<int>? settingsRevision;
  final void Function(String bundleId)? onSetCaptureApp;

  /// Forwarded to the embedded Settings destination's mic-volume "listen"
  /// button (see `SettingsScreen.onSetMicMonitoring`).
  final void Function(bool enabled)? onSetMicMonitoring;
  final Future<List<Clip>> Function()? onCleanUpStorage;
  final ThumbnailCache? thumbnails;
  final DDragon? ddragon;

  /// The live capture engine (for onboarding's live permission polling) and
  /// the relaunch callback (for its "granted mid-session" state) — see
  /// `OnboardingScreen`'s doc.
  final CaptureEngine? engine;
  final VoidCallback? onRelaunch;

  /// Mirrors whether first-run onboarding is the visible screen — flipped
  /// true/false by `_RewindAppState` alongside `_showOnboarding`, and
  /// consulted by `main()`'s `applyBufferPolicy` so onboarding's "Try it
  /// now" step can save a clip at the desktop regardless of
  /// `AppSettings.captureOnlyInGame`. Null (e.g. in widget tests that don't
  /// care) just skips reporting.
  final ValueNotifier<bool>? onboardingActive;

  /// Forwarded to `Shell.steamStatus` — see that field's doc.
  final ValueListenable<String?>? Function()? steamStatus;

  const RewindApp({
    required this.coordinator,
    required this.library,
    required this.settings,
    required this.captureError,
    required this.bufferActive,
    this.bufferAutoPaused,
    required this.displays,
    required this.capturableApps,
    this.audioInputs = const [],
    this.listApps,
    required this.onSettingsChanged,
    required this.onHotkeyRecording,
    required this.onOpenClipsFolder,
    this.settingsRevision,
    this.onSetCaptureApp,
    this.onSetMicMonitoring,
    this.onCleanUpStorage,
    this.thumbnails,
    this.ddragon,
    this.engine,
    this.onRelaunch,
    this.onboardingActive,
    this.steamStatus,
    super.key,
  });

  @override
  State<RewindApp> createState() => _RewindAppState();
}

class _RewindAppState extends State<RewindApp> {
  late bool _showOnboarding = !widget.settings.onboardingComplete;

  /// Set by [_setUpSteam] just before completing onboarding, and consumed
  /// once when the Shell is first built below -- seeds `Shell.
  /// initialDestination` so the "Set up Steam achievements" shortcut lands
  /// straight on Settings' Steam tab. Null (a plain finish/skip) keeps
  /// today's default (All Clips).
  ShellDestination? _shellInitialDestination;

  Future<void> _completeOnboarding() async {
    widget.settings.onboardingComplete = true;
    await widget.onSettingsChanged(widget.settings);
    // Re-arm the buffer policy immediately (see `onboardingActive`'s doc) —
    // must flip BEFORE setState so main()'s listener sees it even if this
    // widget is never rebuilt (e.g. already-unmounted in a test harness).
    widget.onboardingActive?.value = false;
    if (mounted) setState(() => _showOnboarding = false);
  }

  /// Onboarding's "Set up Steam achievements" shortcut: finishes onboarding
  /// exactly like [_completeOnboarding] (same settings persist +
  /// `onboardingActive` flip), then routes the Shell straight to Settings'
  /// Steam tab instead of the usual All Clips landing -- an API key needs a
  /// web visit, so the credential fields themselves stay out of onboarding.
  Future<void> _setUpSteam() async {
    _shellInitialDestination = const SettingsDestination(initialTab: 'Steam');
    await _completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rewind',
      debugShowCheckedModeBanner: false,
      theme: rewindTheme(),
      home: _showOnboarding
          ? OnboardingScreen(
              settings: widget.settings,
              onChanged: widget.onSettingsChanged,
              onDone: _completeOnboarding,
              engine: widget.engine,
              library: widget.library,
              captureError: widget.captureError,
              onRelaunch: widget.onRelaunch,
              listApps: widget.listApps,
              onSetUpSteam: _setUpSteam,
            )
          : Shell(
              coordinator: widget.coordinator,
              library: widget.library,
              captureError: widget.captureError,
              bufferActive: widget.bufferActive,
              bufferAutoPaused: widget.bufferAutoPaused,
              hotkeyLabel: widget.settings.hotkey,
              displays: widget.displays,
              capturableApps: widget.capturableApps,
              audioInputs: widget.audioInputs,
              listApps: widget.listApps,
              onSettingsChanged: widget.onSettingsChanged,
              onOpenClipsFolder: widget.onOpenClipsFolder,
              settingsRevision: widget.settingsRevision,
              onHotkeyRecording: widget.onHotkeyRecording,
              onCleanUpStorage: widget.onCleanUpStorage,
              onSetCaptureApp: widget.onSetCaptureApp,
              onSetMicMonitoring: widget.onSetMicMonitoring,
              thumbnails: widget.thumbnails,
              ddragon: widget.ddragon,
              steamStatus: widget.steamStatus,
              initialDestination: _shellInitialDestination,
            ),
    );
  }
}
