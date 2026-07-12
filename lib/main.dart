import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/clip/clip_library.dart';
import 'src/clip/clips_dir.dart';
import 'src/clip/storage_manager.dart';
import 'src/coordinator/clip_coordinator.dart';
import 'src/events/game_registry.dart';
import 'src/hotkey/hotkey_service.dart';
import 'src/log/log.dart';
import 'src/obs/capture_engine.dart';
import 'src/obs/rewind_obs_engine.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/settings_store.dart';
import 'src/tray/tray_service.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/settings_screen.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  // targets it from the first frame (no-op when null: main display).
  final savedDisplay = settings.captureDisplayUuid;
  if (savedDisplay != null) engine.setCaptureDisplay(savedDisplay);
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

  final coordinator = ClipCoordinator(
    registry: GameRegistry(),
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
  );

  runApp(RewindApp(
    coordinator: coordinator,
    library: library,
    settings: settings,
    captureError: captureError,
    bufferActive: bufferActive,
    onSettingsChanged: (s) async {
      await store.save(s);
      // Apply the (possibly per-game) buffer length to the live engine —
      // without this, a default-length edit only takes effect on the next
      // game-activity transition or app restart.
      engine
          ?.setBufferSeconds(s.bufferSecondsFor(coordinator.activeGame.value));
      if (!await hotkeys.bind(s.hotkey, coordinator.onHotkey)) {
        talker.warning('Could not register hotkey "${s.hotkey}"');
      } else {
        talker.info('Hotkey "${s.hotkey}" registered');
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
  final Future<void> Function(AppSettings) onSettingsChanged;

  const RewindApp({
    required this.coordinator,
    required this.library,
    required this.settings,
    required this.captureError,
    required this.bufferActive,
    required this.onSettingsChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rewind',
      theme: rewindTheme(),
      home: Builder(
        builder: (context) => HomeScreen(
          coordinator: coordinator,
          library: library,
          captureError: captureError,
          bufferActive: bufferActive,
          hotkeyLabel: settings.hotkey,
          onOpenSettings: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(
                settings: settings,
                onChanged: onSettingsChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
