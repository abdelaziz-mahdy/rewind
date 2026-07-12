import 'dart:io';

import 'package:flutter/foundation.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/storage_manager.dart';
import '../events/game_event.dart';
import '../events/game_registry.dart';
import '../log/log.dart';
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

  /// The error from the most recent failed save, for the UI to surface
  /// (e.g. a SnackBar). Null when there is no error to show, including
  /// right after a subsequent successful save.
  final ValueNotifier<String?> lastSaveError = ValueNotifier(null);

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
      final capture = engine;
      if (capture == null) return; // dev mode: no capture backend wired up

      final path = capture.saveClip(outDir);
      if (path == null) {
        final msg = capture.lastError.isNotEmpty
            ? capture.lastError
            : 'Clip save failed';
        _reportSaveError(msg);
        talker.error('Clip save failed: $msg');
        return;
      }

      final file = File(path);
      // The stub shim reports a path without writing anything; never index
      // a clip whose file doesn't exist.
      if (!await file.exists()) {
        talker.warning('Clip save reported a path with no file on disk: '
            '$path');
        return;
      }

      library.add(Clip(
        path: path,
        gameId: e.gameId,
        event: e.kind,
        createdAt: e.time,
        sizeBytes: await file.length(),
      ));
      await library.save();
      await storage.enforce();
      lastSaveError.value = null;
      talker.info('Clip saved: $path');
    } catch (err, stack) {
      // Auto-clip saves are fire-and-forget from the event stream; a failed
      // save (disk full, index write error) must never crash the app.
      talker.handle(err, stack);
      _reportSaveError(err.toString());
    }
  }

  /// Sets [lastSaveError], forcing a notification even when the message is
  /// identical to the previous failure. `ValueNotifier` dedups equal values,
  /// so without the null round-trip a second consecutive identical failure
  /// would never notify listeners — no second SnackBar, reproducing the
  /// "pressed it and nothing happened" complaint. The null pass is harmless:
  /// the UI listener ([HomeScreen]) early-returns on null.
  void _reportSaveError(String msg) {
    lastSaveError.value = null;
    lastSaveError.value = msg;
  }
}
