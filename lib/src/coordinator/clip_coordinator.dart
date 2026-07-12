import 'dart:io';

import 'package:flutter/foundation.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/storage_manager.dart';
import '../events/game_event.dart';
import '../events/game_registry.dart';
import '../obs/capture_engine.dart';
import '../settings/app_settings.dart';

/// Central brain: listens to auto-detected game activity + game events + the
/// global hotkey, applies the active game's per-game config (replay-buffer
/// length, enabled events), saves clips, records them, and enforces storage.
class ClipCoordinator {
  final GameRegistry registry;
  final ClipLibrary library;
  final StorageManager storage;
  final AppSettings settings;
  final CaptureEngine? engine; // null in dev mode (shim not built)
  final String outDir;

  /// The most-recently-activated game, used to attribute manual hotkey clips,
  /// pick the buffer length, and let the UI show what's being captured. Null
  /// when no game is detected.
  final ValueNotifier<String?> activeGame = ValueNotifier(null);

  /// Whether a real capture backend is wired up (false in dev mode).
  bool get captureAvailable => engine != null;

  ClipCoordinator({
    required this.registry,
    required this.library,
    required this.storage,
    required this.settings,
    required this.outDir,
    this.engine,
  });

  void start({bool supervise = true}) {
    // Auto-detection: when a game becomes active, apply its buffer length.
    registry.activity.listen((a) {
      if (a.active) {
        activeGame.value = a.gameId;
        final cfg = settings.configFor(a.gameId);
        engine?.setBufferSeconds(cfg.bufferSeconds);
      } else if (activeGame.value == a.gameId) {
        activeGame.value = null;
        engine?.setBufferSeconds(settings.defaultBufferSeconds);
      }
    });

    // Auto-clip: save when an enabled event fires for the active game.
    registry.events.listen((e) {
      final cfg = settings.configFor(e.gameId);
      if (cfg.autoClip && cfg.enabledEvents.contains(e.kind)) _save(e);
    });

    if (supervise) registry.startSupervising();
  }

  /// Manual hotkey entry point: store the last N seconds (per active game's
  /// buffer length, or the default) immediately.
  Future<void> onHotkey() {
    final gameId = activeGame.value ?? 'desktop';
    return _save(GameEvent(gameId: gameId, kind: GameEventKind.manual));
  }

  Future<void> _save(GameEvent e) async {
    try {
      final path = engine?.saveClip(outDir);
      if (path == null) return; // dev mode or save failed

      final file = File(path);
      // The stub shim reports a path without writing anything; never index
      // a clip whose file doesn't exist.
      if (!await file.exists()) return;

      library.add(Clip(
        path: path,
        gameId: e.gameId,
        event: e.kind,
        createdAt: e.time,
        sizeBytes: await file.length(),
      ));
      await library.save();
      await storage.enforce();
    } catch (err) {
      // Auto-clip saves are fire-and-forget from the event stream; a failed
      // save (disk full, index write error) must never crash the app.
      debugPrint('Rewind: clip save failed: $err');
    }
  }
}
