import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/match_stats.dart';
import '../clip/storage_manager.dart';
import '../events/game_event.dart';
import '../events/game_registry.dart';
import '../games/game_descriptor.dart' show descriptorFor;
import '../log/log.dart';
import '../obs/app_info.dart';
import '../obs/capture_engine.dart';
import '../settings/app_settings.dart';
import '../sound/clip_sounds.dart';
import '../ui/capture_app_match.dart' show usesOfficialLogo;

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

  /// Plays short confirmation sounds for MANUAL save/record actions — see
  /// [ClipSounds]'s doc. Null in tests/dev that don't care about audio;
  /// gated at play time by [AppSettings.playFeedbackSounds] (see
  /// [_feedback]), never baked into the seam itself.
  final ClipSounds? sounds;

  /// Fired fire-and-forget after a clip is successfully indexed (see
  /// [_indexClip]) — the coordinator's hook into the thumbnail pipeline.
  /// A plain callback rather than an injected `ThumbnailCache` so the
  /// coordinator has no dependency on media_kit, matching this class's
  /// existing "pure Dart, testable" shape (§ CLAUDE.md's event-watcher
  /// principle, extended here to the save path).
  final Future<void> Function(Clip)? onClipIndexed;

  /// Per-match kills/deaths, updated as combat events arrive (see
  /// [_rememberEvent]). Null in tests/dev that don't care about K/D.
  final MatchStatsStore? matchStats;

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

  /// Every currently-active game that also counts as PLAYING (see
  /// [GameActivity.countsAsPlaying]) — the buffer policy's input, narrower
  /// than [activeGameIds]. A game whose detection only means "the
  /// launcher/client is open" (e.g. League's catalog entry) shows up in
  /// [activeGameIds] (rail dots, Supported Games, auto-switch, session
  /// stamping all still see it) but never here, so the replay buffer stays
  /// paused under `captureOnlyInGame` until gameplay is actually detected.
  final ValueNotifier<Set<String>> playingGameIds = ValueNotifier(<String>{});

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

  /// Pending [_autoSwitchCaptureFor] retry timers, keyed by gameId — see
  /// [autoSwitchRetryInterval]'s doc. A later activation of the SAME game
  /// replaces (cancels) an older retry rather than stacking two loops.
  final Map<String, Timer> _autoSwitchRetryTimers = {};

  /// How long [_indexClip] waits for a save-reported file to appear on disk
  /// before dropping it (the mux helper can lag the shim's path report
  /// under load). Tests that deliberately report paths with no file (stub
  /// mode) pass [Duration.zero] to skip the wait — which also skips the
  /// completeness settle below.
  final Duration indexFileGrace;

  /// Poll spacing for the file-completeness settle: after the file exists,
  /// [_indexClip] waits until its size stops growing before indexing. An
  /// mp4 the mux is STILL WRITING has no moov atom yet — thumbnailing it
  /// reports "no duration" and the failure is negative-cached, which is
  /// exactly how every clip's thumbnail broke once audio made finalization
  /// slower (2026-07-14 22:08 log).
  final Duration fileSettleInterval;

  /// How long [_autoSwitchCaptureFor]'s retry loop waits between attempts
  /// when no capturable window matches [GameActivity.processMatch] yet —
  /// the gap between a vendor watcher's match-start activation (e.g.
  /// League's Live Client Data API coming up) and ScreenCaptureKit
  /// enumerating the game app's window during the loading screen (verified
  /// live, 2026-07-18: capture stayed bound to the hidden League client and
  /// recorded 28.7 s of black frames because there was no retry at all).
  /// Injectable so tests don't sleep for real seconds.
  final Duration autoSwitchRetryInterval;

  ClipCoordinator({
    required this.registry,
    required this.library,
    required this.storage,
    required this.settings,
    required this.outDir,
    this.engine,
    this.onClipIndexed,
    this.matchStats,
    this.sounds,
    this.indexFileGrace = const Duration(seconds: 5),
    this.fileSettleInterval = const Duration(milliseconds: 250),
    this.burstQuiet,
    this.manualCoalesceWindow = const Duration(seconds: 3),
    this.autoSwitchRetryInterval = const Duration(seconds: 2),
  });

  /// Hotkey presses within this window of the previous press are absorbed
  /// into that press's save — see [onHotkey]. Injectable so tests that
  /// need genuinely sequential manual saves can pass [Duration.zero].
  final Duration manualCoalesceWindow;

  /// Activation time per currently-active gameId — the session (match) key
  /// stamped onto every clip saved while that game stays active (see
  /// [Clip.sessionAt]). Cleared on deactivation, so the next match gets a
  /// fresh key.
  final Map<String, DateTime> _sessionStartedAt = {};

  /// The current session-start stamp for [gameId] (the key its clips and
  /// match stats share), or null when the game isn't active. For tests and
  /// any UI that needs to line clips up with `MatchStatsStore`.
  DateTime? sessionStartedAtFor(String gameId) => _sessionStartedAt[gameId];

  /// How recently a game's newest [MatchStats] must have been updated for a
  /// first-after-launch activation to RESUME that match session instead of
  /// starting a new one. Restarting the app takes well under a minute; a
  /// match whose stats went quiet longer ago than this is a match that
  /// ended, not one the restart interrupted.
  static const sessionResumeWindow = Duration(minutes: 3);

  /// GameIds whose first activation since app launch has already happened —
  /// the restart-resume check ([_sessionStampFor]) only ever applies to the
  /// first one; every later activation is a genuinely new session.
  final Set<String> _sessionResumeChecked = {};

  /// The session stamp for a fresh activation of [a]: normally now. But on
  /// the FIRST activation of this game after app launch, if the game's most
  /// recent persisted match was still being updated moments ago
  /// ([sessionResumeWindow]), the app itself was restarted mid-match — a
  /// fresh stamp would split one real match into two cards (observed live
  /// 2026-07-19 19:42), so the interrupted session's stamp is reused and
  /// its clips/stats keep accumulating onto the same match.
  DateTime _sessionStampFor(GameActivity a) {
    final now = DateTime.now();
    if (!_sessionResumeChecked.add(a.gameId)) return now;
    final latest = matchStats?.latestFor(a.gameId);
    if (latest == null) return now;
    final sinceUpdate = now.difference(latest.updatedAt);
    if (sinceUpdate.isNegative || sinceUpdate > sessionResumeWindow) {
      return now;
    }
    talker.info('Resuming ${a.displayName} match session from '
        '${latest.startedAt.toIso8601String()} (still updating '
        '${sinceUpdate.inSeconds}s ago — app restarted mid-match)');
    return latest.startedAt;
  }

  /// Burst debounce for event-triggered saves. A fight is a BURST of
  /// events; saving on the first one both spams the disk (the 2026-07-14
  /// incident) and cuts the clip before the fight ends, while a plain
  /// cooldown DROPS the follow-up kills (the maintainer's complaint: a kill
  /// at second 25 must extend the clip, not vanish). So: events accumulate
  /// per game, and the save fires once the action goes quiet for the
  /// game's post-event delay (see [_burstQuietFor],
  /// [AppSettings.postEventSecondsFor]/[GameConfig.postEventSeconds]) — one
  /// clip covering the whole fight, labeled with the burst's best event
  /// ([clipPriority]) and killCount for all of it. If waiting any longer
  /// would age the burst's FIRST event out of the replay buffer, the save
  /// fires immediately instead — extension must never turn into loss.
  /// Manual saves are exempt: an explicit ask always saves now.
  ///
  /// TEST OVERRIDE ONLY: when non-null, this wins over the per-game setting
  /// everywhere a quiet window is used (so existing tests that inject a
  /// short fixed value keep working unchanged). Production (`main.dart`)
  /// passes nothing, leaving this null so [_burstQuietFor] resolves the
  /// per-game/default setting instead.
  final Duration? burstQuiet;
  final Map<String, List<GameEvent>> _pendingBurst = {};
  final Map<String, Timer> _burstTimers = {};

  /// The burst-quiet duration to use for [gameId]: the test override
  /// ([burstQuiet]) when set, else the per-game/default setting. See
  /// [burstQuiet]'s doc.
  Duration _burstQuietFor(String gameId) =>
      burstQuiet ?? Duration(seconds: settings.postEventSecondsFor(gameId));

  /// Safety margin between "the burst's first event is this close to
  /// falling out of the buffer" and flushing.
  static const _burstAgeMargin = Duration(seconds: 5);

  void start({bool supervise = true}) {
    // Auto-detection: when a game becomes active, apply its buffer length.
    registry.activity.listen((a) {
      if (a.active) {
        activeGame.value = a.gameId;
        activeGameIds.value = {...activeGameIds.value, a.gameId};
        if (a.countsAsPlaying) {
          playingGameIds.value = {...playingGameIds.value, a.gameId};
        }
        // One session per continuous activation: every clip saved until
        // this game deactivates shares this timestamp, which is what lets
        // the hub group a match's clips together (Clip.sessionAt) — except
        // on an app restart mid-match, where the previous session is
        // resumed instead of splitting the match in two (see
        // [_sessionStampFor]).
        _sessionStartedAt[a.gameId] = _sessionStampFor(a);
        talker.info('Detected ${a.displayName} running');
        final cfg = settings.configFor(a.gameId);
        engine?.setBufferSeconds(cfg.bufferSeconds);
        _autoSwitchCaptureFor(a);
      } else {
        // The match ended with events still pending? Save them before the
        // buffer moves on to desktop footage.
        _flushBurst(a.gameId);
        if (activeGame.value == a.gameId) {
          activeGame.value = null;
          engine?.setBufferSeconds(settings.defaultBufferSeconds);
        }
        activeGameIds.value = {...activeGameIds.value}..remove(a.gameId);
        // Removing an id from a set it was never in (a client-only
        // activation never added to playingGameIds) is a harmless no-op —
        // no need to gate this on countsAsPlaying, which isn't set on
        // deactivation anyway.
        playingGameIds.value = {...playingGameIds.value}..remove(a.gameId);
        _sessionStartedAt.remove(a.gameId);
        // A retry loop still hunting for this game's window is pointless
        // once the game itself is gone — cancel it regardless of whether it
        // ever found a match (a bare cancel here, separate from
        // _revertAutoSwitchFor below, which only acts when THIS game is the
        // one currently switched-to).
        _cancelAutoSwitchRetry(a.gameId);
        _revertAutoSwitchFor(a);
      }
    });

    // Auto-clip: accumulate enabled events into a per-game burst and save
    // once the action goes quiet (see [burstQuiet]'s doc) — one clip per
    // fight, nothing dropped, nothing spammed.
    registry.events.listen((e) {
      // Per-match metadata (champion, teams, mode) — recorded onto the
      // active session's MatchStats, never a clip trigger.
      if (e.kind == GameEventKind.matchInfo) {
        _recordMatchInfo(e);
        return;
      }
      if (e.kind == GameEventKind.statsUpdate) {
        _recordStatsUpdate(e);
        return;
      }
      // Remembered unconditionally (even when auto-clip is off): kill
      // counts on clips must reflect what HAPPENED, not what triggered a
      // save.
      _rememberEvent(e);
      final cfg = settings.configFor(e.gameId);
      if (!(cfg.autoClip && cfg.enabledEvents.contains(e.kind))) return;

      final pending = _pendingBurst.putIfAbsent(e.gameId, () => []);
      pending.add(e);
      final bufferLen = Duration(seconds: settings.bufferSecondsFor(e.gameId));
      final quiet = _burstQuietFor(e.gameId);
      final oldestAge = DateTime.now().difference(pending.first.time);
      if (oldestAge >= bufferLen - quiet - _burstAgeMargin) {
        // Waiting out another quiet period would push the burst's first
        // event past the replay buffer's reach — save now.
        talker.info('Burst flush (buffer limit): ${pending.length} event(s)');
        _flushBurst(e.gameId);
      } else {
        talker.info(
            'Event queued (${e.kind.name}); clip extends while the action '
            'continues');
        _burstTimers[e.gameId]?.cancel();
        _burstTimers[e.gameId] = Timer(quiet, () => _flushBurst(e.gameId));
      }
    });

    if (supervise) registry.startSupervising();
  }

  /// On a game activation, temporarily point the capture target at that
  /// game's running app/window — a "follow the game" convenience that does
  /// NOT persist to [AppSettings.captureAppBundleId] (the user's manually
  /// chosen capture target, which may be unrelated, e.g. a Discord overlay
  /// capture). Reverted by [_revertAutoSwitchFor] when the game exits.
  ///
  /// No-ops when there's no capture backend (dev mode), the setting is off,
  /// or the game has no [GameActivity.processMatch] (some sources have
  /// nothing meaningful to match a window against). When no
  /// currently-capturable app matches yet — e.g. a vendor watcher (League)
  /// activates during the loading screen, before ScreenCaptureKit
  /// enumerates the game app's window — retries every
  /// [autoSwitchRetryInterval] for as long as the game stays active: the
  /// hunt is bounded by the game's own lifecycle (deactivation cancels it),
  /// not by a counted budget (see the comment in [_tryAutoSwitch]). A fresh
  /// activation of the same game cancels any retry already in flight for it
  /// (a later activation replaces an older one, never stacks).
  void _autoSwitchCaptureFor(GameActivity a) {
    // A launcher/client-only activation (countsAsPlaying false) must never
    // STEAL the capture target from its own game's match-live binding.
    // Normally the client activates first and the vendor watcher re-aims
    // second, so ordering hides this — but an app (re)start MID-MATCH races
    // both activations in the same tick, and the client won by 80 ms in a
    // live match (2026-07-19 19:14), stomping the game window with the
    // hidden client app and recording black again. The reverse direction
    // (vendor re-aim overriding the client's earlier switch) stays allowed —
    // that's the Task 15 fix working as designed.
    if (!a.countsAsPlaying) {
      final holder = _autoSwitchedGameId;
      if (holder != null &&
          holder != a.gameId &&
          descriptorFor(a.gameId).mergedGameIds.contains(holder)) {
        return;
      }
    }
    _cancelAutoSwitchRetry(a.gameId);
    _tryAutoSwitch(a, attempt: 1);
  }

  /// One attempt of [_autoSwitchCaptureFor]'s retry loop. [attempt] is
  /// 1-based; on the last allowed attempt with still no match, the loop
  /// gives up instead of scheduling another retry.
  void _tryAutoSwitch(GameActivity a, {required int attempt}) {
    final capture = engine;
    final processMatch = a.processMatch;
    if (capture == null ||
        !settings.autoSwitchCapture ||
        processMatch == null) {
      return;
    }

    // Prefer the on-screen (visible) match over a hidden one. Enumeration
    // spans all Spaces, so a game like native League surfaces BOTH its hidden
    // client/lobby window and its visible in-match window — both named
    // "League of Legends". Binding capture to the lobby records the wrong
    // screen; the on-screen window is the game actually being played. Fall
    // back to the first match when none is on-screen (e.g. the window hasn't
    // appeared yet, or an older shim that didn't report visibility).
    final needle = processMatch.toLowerCase();
    AppInfo? match;
    for (final app in capture.listCapturableApps()) {
      final matches = app.name.toLowerCase().contains(needle) ||
          app.bundleId.toLowerCase().contains(needle);
      if (!matches) continue;
      match ??= app;
      if (app.onScreen) {
        match = app;
        break;
      }
    }
    if (match == null) {
      // No cap: the hunt is bounded by the GAME's own lifecycle, not a
      // count — deactivation (and dispose, and a fresh activation) already
      // cancels the timer. Counted budgets kept losing to reality: 15
      // attempts (30 s) died inside a League Arena loading screen
      // (2026-07-19 19:18, whole next match recorded black), and any
      // bigger number is the same guess with better luck. A no-match poll
      // is one window enumeration every couple of seconds — nothing.
      // Log the first miss and then every 15th, so a long hunt is visible
      // without spamming.
      if (attempt == 1 || attempt % 15 == 0) {
        talker.info('Auto-switch: no running window matched ${a.displayName} '
            'yet (attempt $attempt, retrying until the game exits)');
      }
      _autoSwitchRetryTimers[a.gameId] = Timer(autoSwitchRetryInterval, () {
        _autoSwitchRetryTimers.remove(a.gameId);
        _tryAutoSwitch(a, attempt: attempt + 1);
      });
      return;
    }
    _cancelAutoSwitchRetry(a.gameId);

    // Prefer capturing the matched WINDOW whenever it's actually on screen
    // and has a real window id — window capture is display-agnostic. SCK
    // APP capture composites the app's windows onto ONE anchor display
    // (`display_uuid` is always required, see CLAUDE.md), so a fullscreen
    // game on any other display records black-with-cursor (verified live
    // 2026-07-19: League match, re-aim bound the right GameClient app, clip
    // still black). Window capture of fullscreen games is the proven path —
    // it's what every Wine/CrossOver game (empty bundle id) already uses.
    // A hidden match (e.g. the League client pre-match, not on screen)
    // keeps app capture: window-capturing an off-screen window shows
    // nothing, while app capture at least follows it when it appears.
    if (match.windowId != 0 && (match.onScreen || match.bundleId.isEmpty)) {
      capture.setCaptureWindow(match.windowId);
    } else {
      capture.setCaptureApp(match.bundleId.isEmpty ? null : match.bundleId);
    }
    _autoSwitchedGameId = a.gameId;
    autoSwitchedAppName.value = match.name;
    talker.info('Auto-switched capture to ${match.name}');

    // First real-app match for this game: capture its icon for the rail
    // logo (`GameTileAvatar`), same "capture once, never overwrite" rule as
    // the picker's manual pick path (`_SourceLine._pickApp`) — see
    // `GameConfig.iconPath`'s doc. Wine games have no icon (bundle-less), so
    // this correctly stays null for them, same as the manual path — and so
    // does any Riot game (`usesOfficialLogo`): their app icon IS Riot's
    // official logo, which Riot's policy forbids using; the monogram stays
    // for those. Mutates the shared, in-memory `settings` object only —
    // like every other `configFor` call in this class, it rides along on
    // the next explicit settings save rather than persisting immediately
    // (no `onSettingsChanged` hook is wired into the coordinator).
    if (!usesOfficialLogo(gameId: a.gameId, bundleId: match.bundleId)) {
      settings.configFor(a.gameId).iconPath ??= match.iconPath;
    }
  }

  /// Cancels [gameId]'s pending [_autoSwitchCaptureFor] retry, if any —
  /// called on a successful switch, a fresh activation superseding an older
  /// retry, the game's deactivation, and [dispose].
  void _cancelAutoSwitchRetry(String gameId) {
    _autoSwitchRetryTimers.remove(gameId)?.cancel();
  }

  /// The capture-source picker's path for a Wine app (empty
  /// [AppInfo.bundleId]): start capturing [app]'s window NOW, booked
  /// exactly like an auto-switch for [gameId] — the source line shows
  /// "<name> (auto)" and the game's exit reverts to the persisted
  /// app/display preference via [_revertAutoSwitchFor]. Nothing about the
  /// window is persisted (ids die with the process); the next session's
  /// auto-switch re-resolves a fresh one.
  void captureWineAppWindow(AppInfo app, {required String gameId}) {
    final capture = engine;
    if (capture == null || app.windowId == 0) return;
    capture.setCaptureWindow(app.windowId);
    _autoSwitchedGameId = gameId;
    autoSwitchedAppName.value = app.name;
    talker.info('Capturing ${app.name} (window ${app.windowId})');
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

  /// Cancels pending burst timers without flushing. For tests — in the app
  /// the coordinator lives as long as the process, and shutdown-with-a-
  /// pending-burst is covered by the deactivation flush.
  void dispose() {
    for (final t in _burstTimers.values) {
      t.cancel();
    }
    _burstTimers.clear();
    _pendingBurst.clear();
    for (final t in _autoSwitchRetryTimers.values) {
      t.cancel();
    }
    _autoSwitchRetryTimers.clear();
  }

  /// Saves the pending event burst for [gameId] as ONE clip, labeled with
  /// the burst's highest-priority kind. No-op when nothing is pending.
  void _flushBurst(String gameId) {
    _burstTimers.remove(gameId)?.cancel();
    final pending = _pendingBurst.remove(gameId);
    if (pending == null || pending.isEmpty) return;
    final best = pending
        .reduce((a, b) => clipPriority(b.kind) > clipPriority(a.kind) ? b : a);
    talker.info('Saving clip for ${pending.length} event(s), best: '
        '${best.kind.name}');
    // A fresh event carrying the burst's best kind, timed NOW: the clip's
    // footage window ends at save time, and its killCount is computed from
    // the window — which spans the whole burst.
    _save(GameEvent(gameId: gameId, kind: best.kind, meta: best.meta));
  }

  /// Manual hotkey entry point: store the last N seconds (per active game's
  /// buffer length, or the default) immediately.
  ///
  /// Rapid presses COALESCE into one clip: the in-flight save plus a
  /// [manualCoalesceWindow] absorb window after each press. A user
  /// hammering the key after a big play wants ONE clip, and the buffer
  /// already contains everything the extra presses could ask for;
  /// un-coalesced, the concurrent saves also race the shim's single-flight
  /// replay save ("timed out waiting for replay save", 2026-07-18 16:49)
  /// and the index writes raced each other (see ClipLibrary.save). A
  /// FAILED save clears the window so an immediate retry press works.
  Future<void>? _manualSaveInFlight;
  DateTime? _lastManualPressAt;

  Future<void> onHotkey() {
    final now = DateTime.now();
    final inFlight = _manualSaveInFlight;
    final last = _lastManualPressAt;
    if (inFlight != null ||
        (last != null && now.difference(last) < manualCoalesceWindow)) {
      talker.debug('Hotkey press coalesced into the save already under way');
      return inFlight ?? Future.value();
    }
    _lastManualPressAt = now;
    final gameId = activeGame.value ?? 'desktop';
    final save = _save(GameEvent(gameId: gameId, kind: GameEventKind.manual))
        .whenComplete(() {
      _manualSaveInFlight = null;
      // A FAILED save must not swallow the user's next press — pressing
      // again right after an error is a retry, not spam.
      if (lastSaveError.value != null) _lastManualPressAt = null;
    });
    _manualSaveInFlight = save;
    return save;
  }

  Future<void> _save(GameEvent e) async {
    // Only a manual (hotkey/`.save-now`) save sounds — auto-clipped events
    // never do, see [ClipSounds]'s doc. Hooked here, at the SAVE COMPLETION,
    // rather than in [onHotkey]'s entry: a coalesced press never reaches
    // this method at all (it just awaits the in-flight save), so this point
    // naturally plays exactly once per completed save, coalesced or not.
    final manual = e.kind == GameEventKind.manual;
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
        if (manual) _feedback((s) => s.saveFailed());
        return;
      }

      await _indexClip(path, e);
      if (manual) _feedback((s) => s.saveSucceeded());
    } catch (err, stack) {
      // Auto-clip saves are fire-and-forget from the event stream; a failed
      // save (disk full, index write error) must never crash the app.
      talker.handle(err, stack);
      _reportSaveError(err.toString());
      if (manual) _feedback((s) => s.saveFailed());
    }
  }

  /// Plays [play] on [sounds] when both a sound seam is wired up and
  /// [AppSettings.playFeedbackSounds] is currently on — read live at call
  /// time (same as every other coordinator setting read), so a mid-session
  /// toggle takes effect on the very next save/record without needing a
  /// restart.
  void _feedback(void Function(ClipSounds) play) {
    final s = sounds;
    if (s != null && settings.playFeedbackSounds) play(s);
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
        _feedback((s) => s.recordingStarted());
      } catch (err, stack) {
        talker.handle(err, stack);
        _reportSaveError(err.toString());
      }
      return;
    }

    final gameId = activeGame.value ?? 'desktop';
    // The recording's kill count spans its whole session, not the buffer
    // window — grab the start before clearing it below.
    final startedAt = recordingStartedAt.value;
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
      // The manual toggle confirming its state change (stop) is what
      // sounds — not the indexing that follows, which can lag or fail
      // independently of the recording having actually stopped.
      _feedback((s) => s.recordingStopped());

      await _indexClip(
          path, GameEvent(gameId: gameId, kind: GameEventKind.recording),
          windowStart: startedAt);
    } catch (err, stack) {
      talker.handle(err, stack);
      _reportSaveError(err.toString());
    }
  }

  /// Recent game events (every kind, unfiltered), kept so a clip can be
  /// annotated with what happened INSIDE its footage window — e.g. how many
  /// kills a recording covers ([Clip.killCount]). Pruned to the last 20
  /// minutes; long recordings just count the retained tail.
  final List<GameEvent> _recentEvents = [];
  static const _recentEventsRetention = Duration(minutes: 20);

  /// Writes a [GameEventKind.matchInfo] event's metadata onto the active
  /// session's MatchStats (same session key its clips/kills share).
  void _recordMatchInfo(GameEvent e) {
    final sessionStart = _sessionStartedAt[e.gameId];
    final stats = matchStats;
    if (sessionStart == null || stats == null) return;
    stats.recordMatchInfo(
      e.gameId,
      sessionStart,
      gameMode: e.meta['gameMode'] as String?,
      champion: e.meta['champion'] as String?,
      allies: _parsePlayers(e.meta['allies']),
      enemies: _parsePlayers(e.meta['enemies']),
      rawChampionName: e.meta['rawChampionName'] as String?,
      skinName: e.meta['skinName'] as String?,
    );
  }

  /// Parses a matchInfo event's `allies`/`enemies` meta (a `List` of
  /// champion+name maps, see `LeagueEventWatcher._emitMatchInfo`) into
  /// [MatchPlayer]s. Null passthrough for a missing key.
  static List<MatchPlayer>? _parsePlayers(Object? raw) =>
      (raw as List?)?.map(MatchPlayer.fromDynamic).toList();

  /// Writes a [GameEventKind.statsUpdate] event's live snapshot
  /// (assists/creepScore/wardScore/items) onto the active session's
  /// MatchStats — same session-key contract as [_recordMatchInfo], except
  /// this fires every poll (see that event kind's doc) rather than once;
  /// [MatchStatsStore.recordStatsUpdate] is what keeps the actual disk
  /// writes cheap by no-opping when nothing changed.
  void _recordStatsUpdate(GameEvent e) {
    final sessionStart = _sessionStartedAt[e.gameId];
    final stats = matchStats;
    if (sessionStart == null || stats == null) return;
    final items = (e.meta['items'] as List?)
        ?.map((i) => MatchItemSlot.fromJson((i as Map).cast<String, dynamic>()))
        .toList();
    stats.recordStatsUpdate(
      e.gameId,
      sessionStart,
      assists: e.meta['assists'] as int?,
      creepScore: e.meta['creepScore'] as int?,
      wardScore: e.meta['wardScore'] as double?,
      items: items,
    );
  }

  void _rememberEvent(GameEvent e) {
    _recentEvents.add(e);
    final cutoff = DateTime.now().subtract(_recentEventsRetention);
    _recentEvents.removeWhere((ev) => ev.time.isBefore(cutoff));

    // Match K/D + timeline markers: attribute every event to the game's
    // CURRENT session (the same stamp its clips carry, see [Clip.sessionAt])
    // via the single [MatchStatsStore.recordEvent] path — counted/stamped
    // for the whole match regardless of clip settings, so a death (never
    // clipped) still counts toward the match summary, and every kind (kills,
    // deaths, objectives, aces) lands a marker on the player timeline (see
    // `lib/src/clip/clip_markers.dart`).
    final sessionStart = _sessionStartedAt[e.gameId];
    final stats = matchStats;
    if (sessionStart != null && stats != null) {
      stats.recordEvent(e.gameId, sessionStart, e.kind, e.time);
    }
  }

  /// Kills by the player inside [start]..[end] for [gameId] — the clip
  /// annotation. Counts only `kill` events: each Multikill arrives WITH its
  /// ChampionKill, so counting both would double-count.
  int _killsInWindow(String gameId, DateTime start, DateTime end) =>
      _recentEvents
          .where((ev) =>
              ev.gameId == gameId &&
              ev.kind == GameEventKind.kill &&
              !ev.time.isBefore(start) &&
              !ev.time.isAfter(end))
          .length;

  /// Shared "wrap a capture-engine-reported path into the clip library"
  /// logic for both [_save] (replay buffer) and [toggleRecording] (manual
  /// recording): guards against a reported path with no file on disk (the
  /// stub shim reports a path without writing anything), indexes the clip,
  /// persists the library, enforces the storage cap, and clears the last
  /// save error. [windowStart] overrides the footage window's start for
  /// kill counting (a manual recording's session start); buffer clips
  /// default to the game's replay-buffer length before the event.
  Future<void> _indexClip(String path, GameEvent e,
      {DateTime? windowStart}) async {
    final file = File(path);
    // The shim's save can report the path slightly before the mux helper
    // finishes writing the file, especially with the encoder under load —
    // during the 2026-07-14 save-spam incident EVERY clip hit this window
    // and silently vanished from the library. Give the file a bounded
    // moment to land before declaring it missing.
    final deadline = DateTime.now().add(indexFileGrace);
    while (!await file.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        talker.warning('Clip save reported a path with no file on disk: '
            '$path');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Existing is not finished: wait for the size to stop growing (see
    // [fileSettleInterval]) so thumbnails/size are read from a COMPLETE
    // file. Bounded by a fresh grace budget; if it's somehow still growing
    // then, index what's there rather than dropping the clip.
    if (indexFileGrace > Duration.zero) {
      final settleDeadline = DateTime.now().add(indexFileGrace);
      var lastLen = await _safeLength(file);
      while (DateTime.now().isBefore(settleDeadline)) {
        await Future<void>.delayed(fileSettleInterval);
        final len = await _safeLength(file);
        if (len == lastLen && len > 0) break;
        lastLen = len;
      }
    }

    final size = await _safeLength(file);

    final windowEnd = e.time;
    final start = windowStart ??
        windowEnd
            .subtract(Duration(seconds: settings.bufferSecondsFor(e.gameId)));
    final clip = Clip(
      path: path,
      gameId: e.gameId,
      event: e.kind,
      createdAt: e.time,
      sizeBytes: size < 0 ? 0 : size,
      sessionAt: _sessionStartedAt[e.gameId],
      killCount: _killsInWindow(e.gameId, start, windowEnd),
      // A per-instance label (e.g. a Steam achievement's real display
      // name — see `SteamAchievementWatcher`) when the source supplied
      // one; null for every event kind that doesn't (the generic
      // kind-derived badge, `eventBadge`, is all those need).
      eventLabel: e.meta['label'] as String?,
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

  /// `File.length()` can transiently throw on Windows — a `PathNotFoundException`
  /// (a `FileSystemException`) from handle contention with the still-open mux
  /// writer, even for a file that exists. Return -1 on failure so the settle
  /// loop keeps polling and a clip is never dropped (nor an unhandled async
  /// error raised) over a momentary read hiccup. macOS/Linux never hit this.
  Future<int> _safeLength(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return -1;
    }
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
