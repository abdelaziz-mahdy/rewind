import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/storage_manager.dart';
import '../events/game_event.dart';
import '../events/game_registry.dart';
import '../log/log.dart';
import '../obs/app_info.dart';
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

  /// Fired fire-and-forget after a clip is successfully indexed (see
  /// [_indexClip]) — the coordinator's hook into the thumbnail pipeline.
  /// A plain callback rather than an injected `ThumbnailCache` so the
  /// coordinator has no dependency on media_kit, matching this class's
  /// existing "pure Dart, testable" shape (§ CLAUDE.md's event-watcher
  /// principle, extended here to the save path).
  final Future<void> Function(Clip)? onClipIndexed;

  /// The most-recently-activated game, used to attribute manual hotkey clips,
  /// pick the buffer length, and let the UI show what's being captured. Null
  /// when no game is detected.
  final ValueNotifier<String?> activeGame = ValueNotifier(null);

  /// Every currently-active game, mirroring [GameRegistry.activeGameIds] as a
  /// notifier so UI (the rail's live dots, the game hub, Supported Games) can
  /// listen without polling the registry directly. Unlike [activeGame] (only
  /// the most-recently-activated game, used to attribute manual hotkey
  /// clips), multiple games can be live at once — e.g. a process-detected
  /// background app alongside League — and this tracks all of them.
  final ValueNotifier<Set<String>> activeGameIds = ValueNotifier(<String>{});

  /// The error from the most recent failed save, for the UI to surface
  /// (e.g. a SnackBar). Null when there is no error to show, including
  /// right after a subsequent successful save.
  final ValueNotifier<String?> lastSaveError = ValueNotifier(null);

  /// Whether a real capture backend is wired up (false in dev mode).
  bool get captureAvailable => engine != null;

  /// Whether a manual recording session (`CaptureEngine.startRecording`) is
  /// currently in progress. Independent of the rolling replay buffer — both
  /// can run at once.
  final ValueNotifier<bool> isRecording = ValueNotifier(false);

  /// When the current recording session started, for the deck's elapsed-time
  /// readout. Null whenever [isRecording] is false.
  final ValueNotifier<DateTime?> recordingStartedAt = ValueNotifier(null);

  /// The game whose capture target we auto-switched to (see
  /// [_autoSwitchCaptureFor]), so [_revertAutoSwitchFor] only reverts when
  /// THAT specific game deactivates — not some unrelated game exiting while
  /// the switched-to game is still running.
  String? _autoSwitchedGameId;

  /// The name of the app capture was auto-switched to (see
  /// [_autoSwitchCaptureFor]), for the UI to show what's actually being
  /// captured while a "follow the game" auto-switch is in effect — as
  /// opposed to [AppSettings.captureAppBundleId]/[AppSettings.captureDisplayUuid],
  /// the persisted choice the UI otherwise reflects, which auto-switch
  /// deliberately does not touch. Null when no auto-switch is active.
  final ValueNotifier<String?> autoSwitchedAppName = ValueNotifier(null);

  ClipCoordinator({
    required this.registry,
    required this.library,
    required this.storage,
    required this.settings,
    required this.outDir,
    this.engine,
    this.onClipIndexed,
  });

  void start({bool supervise = true}) {
    // Auto-detection: when a game becomes active, apply its buffer length.
    registry.activity.listen((a) {
      if (a.active) {
        activeGame.value = a.gameId;
        activeGameIds.value = {...activeGameIds.value, a.gameId};
        talker.info('Detected ${a.displayName} running');
        final cfg = settings.configFor(a.gameId);
        engine?.setBufferSeconds(cfg.bufferSeconds);
        _autoSwitchCaptureFor(a);
      } else {
        if (activeGame.value == a.gameId) {
          activeGame.value = null;
          engine?.setBufferSeconds(settings.defaultBufferSeconds);
        }
        activeGameIds.value = {...activeGameIds.value}..remove(a.gameId);
        _revertAutoSwitchFor(a);
      }
    });

    // Auto-clip: save when an enabled event fires for the active game.
    registry.events.listen((e) {
      final cfg = settings.configFor(e.gameId);
      if (cfg.autoClip && cfg.enabledEvents.contains(e.kind)) _save(e);
    });

    if (supervise) registry.startSupervising();
  }

  /// On a game activation, temporarily point the capture target at that
  /// game's running app/window — a "follow the game" convenience that does
  /// NOT persist to [AppSettings.captureAppBundleId] (the user's manually
  /// chosen capture target, which may be unrelated, e.g. a Discord overlay
  /// capture). Reverted by [_revertAutoSwitchFor] when the game exits.
  ///
  /// No-ops when: there's no capture backend (dev mode), the setting is
  /// off, the game has no [GameActivity.processMatch] (vendor-API sources
  /// like League have no OS process to match against a window), or no
  /// currently-capturable app matches yet (e.g. the game's window hasn't
  /// appeared yet — no retry loop in this round, a future refinement).
  void _autoSwitchCaptureFor(GameActivity a) {
    final capture = engine;
    final processMatch = a.processMatch;
    if (capture == null ||
        !settings.autoSwitchCapture ||
        processMatch == null) {
      return;
    }

    final needle = processMatch.toLowerCase();
    AppInfo? match;
    for (final app in capture.listCapturableApps()) {
      if (app.name.toLowerCase().contains(needle) ||
          app.bundleId.toLowerCase().contains(needle)) {
        match = app;
        break;
      }
    }
    if (match == null) {
      talker
          .info('Auto-switch: no running window matched ${a.displayName} yet');
      return;
    }

    capture.setCaptureApp(match.bundleId);
    _autoSwitchedGameId = a.gameId;
    autoSwitchedAppName.value = match.name;
    talker.info('Auto-switched capture to ${match.name}');
  }

  /// Reverts an auto-switch made by [_autoSwitchCaptureFor], but only when
  /// the deactivating game [a] is the one we switched for — an unrelated
  /// game exiting must not clobber the still-running game's capture target.
  void _revertAutoSwitchFor(GameActivity a) {
    if (_autoSwitchedGameId != a.gameId) return;
    _autoSwitchedGameId = null;
    autoSwitchedAppName.value = null;
    engine?.setCaptureApp(settings.captureAppBundleId);
    talker.info('Reverted capture after ${a.displayName} exited');
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

      await _indexClip(path, e);
    } catch (err, stack) {
      // Auto-clip saves are fire-and-forget from the event stream; a failed
      // save (disk full, index write error) must never crash the app.
      talker.handle(err, stack);
      _reportSaveError(err.toString());
    }
  }

  /// Manual recording entry point: starts a continuous recording session on
  /// first call, stops and saves it (as a [GameEventKind.recording] clip) on
  /// the next — independent of the rolling replay buffer, which keeps
  /// running throughout. No-ops when there's no capture backend (dev mode).
  Future<void> toggleRecording() async {
    final capture = engine;
    if (capture == null) return; // dev mode: no capture backend wired up

    // Re-entrancy guard: stopRecording is a synchronous FFI call that can
    // block the isolate for a moment; a tap queued during that block would
    // otherwise land after isRecording flipped and spuriously START a new
    // recording ("double-tap to stop" ends up recording again).
    if (_togglingRecording) return;
    _togglingRecording = true;
    try {
      await _toggleRecordingInner(capture);
    } finally {
      _togglingRecording = false;
    }
  }

  bool _togglingRecording = false;

  Future<void> _toggleRecordingInner(CaptureEngine capture) async {
    if (!isRecording.value) {
      try {
        if (!capture.startRecording(outDir)) {
          final msg = capture.lastError.isNotEmpty
              ? capture.lastError
              : 'Recording failed to start';
          _reportSaveError(msg);
          talker.error('Recording failed to start: $msg');
          return;
        }
        isRecording.value = true;
        recordingStartedAt.value = DateTime.now();
        talker.info('Recording started');
      } catch (err, stack) {
        talker.handle(err, stack);
        _reportSaveError(err.toString());
      }
      return;
    }

    final gameId = activeGame.value ?? 'desktop';
    // The engine-side session ends with this call either way (success or
    // failure) — clear local state up front so a failed save below doesn't
    // leave the deck stuck showing "recording".
    isRecording.value = false;
    recordingStartedAt.value = null;
    try {
      final path = capture.stopRecording();
      if (path == null) {
        final msg = capture.lastError.isNotEmpty
            ? capture.lastError
            : 'Recording save failed';
        _reportSaveError(msg);
        talker.error('Recording save failed: $msg');
        return;
      }

      await _indexClip(
          path, GameEvent(gameId: gameId, kind: GameEventKind.recording));
    } catch (err, stack) {
      talker.handle(err, stack);
      _reportSaveError(err.toString());
    }
  }

  /// Shared "wrap a capture-engine-reported path into the clip library"
  /// logic for both [_save] (replay buffer) and [toggleRecording] (manual
  /// recording): guards against a reported path with no file on disk (the
  /// stub shim reports a path without writing anything), indexes the clip,
  /// persists the library, enforces the storage cap, and clears the last
  /// save error.
  Future<void> _indexClip(String path, GameEvent e) async {
    final file = File(path);
    if (!await file.exists()) {
      talker.warning('Clip save reported a path with no file on disk: '
          '$path');
      return;
    }

    final clip = Clip(
      path: path,
      gameId: e.gameId,
      event: e.kind,
      createdAt: e.time,
      sizeBytes: await file.length(),
    );
    library.add(clip);
    await library.save();
    await storage.enforce();
    lastSaveError.value = null;
    talker.info('Clip saved: $path');

    // Fire-and-forget: thumbnail generation must never delay or fail a save.
    final hook = onClipIndexed;
    if (hook != null) unawaited(hook(clip));
  }

  /// Sets [lastSaveError], forcing a notification even when the message is
  /// identical to the previous failure. `ValueNotifier` dedups equal values,
  /// so without the null round-trip a second consecutive identical failure
  /// would never notify listeners — no second SnackBar, reproducing the
  /// "pressed it and nothing happened" complaint. The null pass is harmless:
  /// the UI listener (the Shell) early-returns on null.
  void _reportSaveError(String msg) {
    lastSaveError.value = null;
    lastSaveError.value = msg;
  }
}
