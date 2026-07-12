import 'dart:io';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/storage_manager.dart';
import '../events/game_event.dart';
import '../events/game_registry.dart';
import '../obs/rewind_obs_ffi.dart';

/// Central brain: listens to game events + the hotkey, decides whether to save
/// a clip, records it in the library, and runs storage enforcement.
class ClipCoordinator {
  final GameRegistry registry;
  final ClipLibrary library;
  final StorageManager storage;
  final RewindObs? obs; // null in dev mode (shim not loaded)
  final String outDir;

  /// Which event kinds the user wants auto-clipped.
  final Set<GameEventKind> enabledEvents;

  ClipCoordinator({
    required this.registry,
    required this.library,
    required this.storage,
    required this.outDir,
    this.obs,
    Set<GameEventKind>? enabledEvents,
  }) : enabledEvents = enabledEvents ??
            {
              GameEventKind.manual,
              GameEventKind.kill,
              GameEventKind.doubleKill,
              GameEventKind.tripleKill,
              GameEventKind.quadraKill,
              GameEventKind.pentaKill,
              GameEventKind.ace,
            };

  void start() {
    registry.events.listen((e) {
      if (enabledEvents.contains(e.kind)) _save(e);
    });
    registry.startSupervising();
  }

  /// Manual hotkey entry point.
  void onHotkey() => _save(GameEvent(gameId: 'manual', kind: GameEventKind.manual));

  Future<void> _save(GameEvent e) async {
    final path = obs?.saveClip(outDir);
    if (path == null) return; // dev mode or save failed

    final size = await _sizeOf(path);
    library.add(Clip(
      path: path,
      gameId: e.gameId,
      event: e.kind,
      createdAt: e.time,
      sizeBytes: size,
    ));
    await storage.enforce();
  }

  Future<int> _sizeOf(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }
}
