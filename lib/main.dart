import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'src/clip/clip_library.dart';
import 'src/clip/clips_dir.dart';
import 'src/clip/storage_manager.dart';
import 'src/coordinator/clip_coordinator.dart';
import 'src/events/game_registry.dart';
import 'src/events/source_builder.dart';
import 'src/hotkey/hotkey_service.dart';
import 'src/log/log.dart';
import 'src/obs/app_info.dart';
import 'src/obs/capture_engine.dart';
import 'src/obs/display_info.dart';
import 'src/obs/rewind_obs_engine.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/settings_store.dart';
import 'src/tray/tray_service.dart';
import 'src/ui/shell.dart';
import 'src/ui/theme.dart';

/// Reveals the clips folder in the OS file manager — shared by the Home
/// AppBar/empty-state buttons and the tray's "Open clips folder" item.
/// Best-effort: no OS handler available (or an unsupported platform) is not
/// fatal, mirroring `ClipTile`'s own `_open`/`_reveal` helpers.
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

  final store = SettingsStore(await getApplicationSupportDirectory());
  final settings = await store.load();
  final clipsDir = await ensureClipsDir();
  final library = await ClipLibrary.load(clipsDir);

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

  final coordinator = ClipCoordinator(
    registry: GameRegistry(sources: buildSources(settings)),
    library: library,
    storage: StorageManager(library),
    settings: settings,
    outDir: clipsDir.path,
    engine: engine,
  )..start();

  final hotkeys = HotkeyService();
  if (!await hotkeys.bind(settings.hotkey, coordinator.onHotkey)) {
    talker.warning('Could not register hotkey "${settings.hotkey}"');
  } else {
    talker.info('Hotkey "${settings.hotkey}" registered');
  }

  if (kDebugMode) {
    // Headless save trigger for integration tests (and agent-driven
    // verification): touching <clipsDir>/.save-now behaves like the hotkey.
    // Debug builds only; never active in release.
    final trigger = File('${clipsDir.path}/.save-now');
    Timer.periodic(const Duration(seconds: 1), (_) async {
      if (trigger.existsSync()) {
        try {
          trigger.deleteSync();
        } catch (_) {}
        await coordinator.onHotkey();
      }
    });
  }

  // Live buffer state shared by the status strip and the tray toggle.
  final bufferActive =
      ValueNotifier<bool>(engine != null && captureError == null);

  // Bumped at the end of every settings change (see StatusStrip's
  // settingsRevision doc) so the capture-source chip and buffer readout
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
  // Seed the tray's toggle label from the real startup state — its internal
  // default assumes an active buffer, which is wrong when capture failed.
  await tray.setBufferState(bufferActive.value);

  runApp(RewindApp(
    coordinator: coordinator,
    library: library,
    settings: settings,
    captureError: captureError,
    bufferActive: bufferActive,
    displays: displays,
    capturableApps: capturableApps,
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
      if (!await hotkeys.bind(s.hotkey, coordinator.onHotkey)) {
        talker.warning('Could not register hotkey "${s.hotkey}"');
      } else {
        talker.info('Hotkey "${s.hotkey}" registered');
      }
      settingsRevision.value++;
    },
    onSetCaptureApp: (bundleId) => engine?.setCaptureApp(bundleId),
    onHotkeyRecording: (recording) async {
      if (recording) {
        // Suspend the live global hotkey while the recorder is listening:
        // otherwise pressing the currently-bound combo mid-record both
        // fires a spurious save and, since the OS owns it at system scope,
        // may never reach the recorder's key handler at all — making it
        // impossible to re-record the hotkey that's already in use.
        await hotkeys.dispose();
        return;
      }
      // Recording ended WITHOUT a capture (Escape / click away / navigated
      // off Settings): re-bind the still-unchanged `settings.hotkey`,
      // restoring what was live before recording started. The successful
      // capture path deliberately does NOT reach here — onSettingsChanged
      // owns that rebind, and a second concurrent unregisterAll+register
      // cycle could interleave into a double registration (one press,
      // two saved clips).
      if (!await hotkeys.bind(settings.hotkey, coordinator.onHotkey)) {
        talker.warning('Could not re-register hotkey "${settings.hotkey}"');
      } else {
        talker.info('Hotkey "${settings.hotkey}" re-registered');
      }
    },
  ));
}

class RewindApp extends StatelessWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;
  final AppSettings settings;
  final String? captureError;
  final ValueNotifier<bool> bufferActive;
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;
  final Future<void> Function(AppSettings) onSettingsChanged;
  final Future<void> Function(bool recording) onHotkeyRecording;
  final VoidCallback onOpenClipsFolder;
  final ValueListenable<int>? settingsRevision;
  final void Function(String bundleId)? onSetCaptureApp;

  const RewindApp({
    required this.coordinator,
    required this.library,
    required this.settings,
    required this.captureError,
    required this.bufferActive,
    required this.displays,
    required this.capturableApps,
    required this.onSettingsChanged,
    required this.onHotkeyRecording,
    required this.onOpenClipsFolder,
    this.settingsRevision,
    this.onSetCaptureApp,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rewind',
      theme: rewindTheme(),
      home: Shell(
        coordinator: coordinator,
        library: library,
        captureError: captureError,
        bufferActive: bufferActive,
        hotkeyLabel: settings.hotkey,
        displays: displays,
        capturableApps: capturableApps,
        onSettingsChanged: onSettingsChanged,
        onOpenClipsFolder: onOpenClipsFolder,
        settingsRevision: settingsRevision,
        onHotkeyRecording: onHotkeyRecording,
        onSetCaptureApp: onSetCaptureApp,
      ),
    );
  }
}
