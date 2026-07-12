import 'package:flutter/material.dart';

import 'src/clip/clip_library.dart';
import 'src/clip/storage_manager.dart';
import 'src/coordinator/clip_coordinator.dart';
import 'src/events/game_registry.dart';
import 'src/obs/rewind_obs_ffi.dart';
import 'src/settings/app_settings.dart';

void main() {
  runApp(const RewindApp());
}

class RewindApp extends StatefulWidget {
  const RewindApp({super.key});

  @override
  State<RewindApp> createState() => _RewindAppState();
}

class _RewindAppState extends State<RewindApp> {
  // Read by nothing yet — the UI screens land in v0.1 integration.
  // ignore: unused_field
  late final ClipCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    final library = ClipLibrary();
    final settings = AppSettings(); // TODO: load/persist from disk
    final obs = RewindObs.tryLoad();
    // TODO: resolve a real per-OS clips directory via path_provider.
    const outDir = 'clips';
    obs?.init(outDir: outDir, seconds: settings.defaultBufferSeconds);
    obs?.startBuffer();

    _coordinator = ClipCoordinator(
      registry: GameRegistry(),
      library: library,
      storage: StorageManager(library),
      settings: settings,
      outDir: outDir,
      obs: obs,
    )..start();
    // TODO: register the global hotkey (hotkey_manager) -> _coordinator.onHotkey()
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rewind',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Rewind')),
        body: const Center(
          child: Text(
            'Rewind is running.\nAuto-detect games, buffer replay, clip on hotkey or event.\n'
            'See ROADMAP.md for what is being built.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
