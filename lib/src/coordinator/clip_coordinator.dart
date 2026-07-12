import 'dart:io';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/storage_manager.dart';
import '../events/game_event.dart';
import '../events/game_registry.dart';
import '../obs/rewind_obs_ffi.dart';
import '../settings/app_settings.dart';

/// Central brain: listens to auto-detected game activity + game events + the
/// global hotkey, applies the active game's per-game config (replay-buffer
/// length, enabled events), saves clips, records them, and enforces storage.
class ClipCoordinator {
  final GameRegistry registry;
  final ClipLibrary library;
  final StorageManager storage;
  final AppSettings settings;
  final RewindObs? obs; // null in dev mode (shim not built)
  final String outDir;

  /// The most-recently-activated game, used to attribute manual hotkey clips
  /// and to pick the buffer length. Null when no game is detected.
  String? _activeGameId;

  ClipCoordinator({
    required this.registry,
    required this.library,
    required this.storage,
    required this.settings,
    required this.outDir,
    this.obs,
  });

  void start() {
    // Auto-detection: when a game becomes active, apply its buffer length.
    registry.activity.listen((a) {
      if (a.active) {
        _activeGameId = a.gameId;
        final cfg = settings.configFor(a.gameId);
        obs?.setBufferSeconds(cfg.bufferSeconds);
      } else if (_activeGameId == a.gameId) {
        _activeGameId = null;
        obs?.setBufferSeconds(settings.defaultBufferSeconds);
      }
    });

    // Auto-clip: save when an enabled event fires for the active game.
    registry.events.listen((e) {
      final cfg = settings.configFor(e.gameId);
      if (cfg.autoClip && cfg.enabledEvents.contains(e.kind)) _save(e);
    });

    registry.startSupervising();
  }

  /// Manual hotkey entry point: store the last N seconds (per active game's
  /// buffer length, or the default) immediately.
  void onHotkey() {
    final gameId = _activeGameId ?? 'desktop';
    _save(GameEvent(gameId: gameId, kind: GameEventKind.manual));
  }

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
