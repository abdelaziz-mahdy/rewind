import 'package:flutter/material.dart';

import 'src/clip/clip_library.dart';
import 'src/clip/storage_manager.dart';
import 'src/coordinator/clip_coordinator.dart';
import 'src/events/game_registry.dart';
import 'src/obs/rewind_obs_ffi.dart';

void main() {
  runApp(const RewindApp());
}

class RewindApp extends StatefulWidget {
  const RewindApp({super.key});

  @override
  State<RewindApp> createState() => _RewindAppState();
}

class _RewindAppState extends State<RewindApp> {
  late final ClipCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    final library = ClipLibrary();
    final obs = RewindObs.tryLoad(); // null until the native shim is built
    // TODO: resolve a real per-OS clips directory via path_provider.
    const outDir = 'clips';
    obs?.init(outDir: outDir, seconds: 30);
    obs?.startBuffer();

    _coordinator = ClipCoordinator(
      registry: GameRegistry(),
      library: library,
      storage: StorageManager(library),
      outDir: outDir,
      obs: obs,
    )..start();
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
            'Rewind is running.\nReplay buffer + auto-clip scaffold.\n'
            'See ROADMAP.md for what is being built.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
