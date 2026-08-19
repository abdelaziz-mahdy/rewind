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
import '../log/obs_log.dart';
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

  /// An explanation, NOT a failure: the user asked to clip while the buffer
  /// was deliberately paused, so there was nothing recorded to save.
  ///
  /// Kept separate from [lastSaveError] because the two deserve opposite
  /// treatment on screen. Pressing Clip at the desktop with "only record
  /// while playing" on used to raise the same red "Couldn't save clip:
  /// buffer not running" as a genuine failure — the app's own setting
  /// working as configured, reported as if something had broken, in the
  /// shim's words rather than the user's.
  final ValueNotifier<String?> lastSaveNotice = ValueNotifier(null);

  /// The clip from the most recent MANUAL save (hotkey / "Save clip"
  /// button) once it's indexed, for the UI to confirm visibly (a SnackBar —
  /// see the Shell). Manual only: event auto-saves mid-game would spam
  /// toasts over gameplay, and their confirmation is the clip appearing in
  /// the library the user is usually looking at anyway. Set via the same
  /// null round-trip trick as [lastSaveError] so back-to-back saves both
  /// notify.
  final ValueNotifier<Clip?> lastManualSave = ValueNotifier(null);

  /// True while the replay buffer is known to be dead — libobs stopped the
  /// output underneath us and a restart didn't take (see
  /// [_recoverIfBufferDied]). The UI reads this so "nothing is being
  /// captured" can't keep rendering as ARMED, which is exactly how an
  /// evening of clips was lost without anyone noticing.
  final ValueNotifier<bool> captureDown = ValueNotifier(false);

  /// Whether the buffer is SUPPOSED to be running right now — `main.dart`'s
  /// `bufferActive`, the output of `desiredBufferActive()` (see
  /// `buffer_policy.dart`). Read by [_recoverIfBufferDied] so a buffer that
  /// is stopped ON PURPOSE — "Only record while playing" with no game up, or
  /// a manual tray pause — is never mistaken for one that crashed.
  ///
  /// Without this the recovery logic fought the pause policy: pressing the
  /// hotkey at the desktop logged a false error and force-restarted a buffer
  /// the user had asked to stay off, burning the CPU and battery that
  /// setting exists to save. Null (tests, dev mode) assumes the buffer
  /// should be running, which is the honest default when nobody has said
  /// otherwise.
  ValueListenable<bool>? bufferShouldBeRunning;

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

  /// The capture target [_tryAutoSwitch] last bound, as `w:<windowId>` or
  /// `a:<bundleId>`. The supervision loop re-binds only when the game's
  /// resolved target DIFFERS from this — re-issuing the same target every
  /// couple of seconds would tear down and rebuild the ScreenCaptureKit
  /// stream for nothing, and leaving a manual mid-game source pick alone
  /// (the user's explicit choice) falls out of the same check.
  String? _autoSwitchedTarget;

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
  /// This is the STEADY interval; the first [_fastHuntAttempts] attempts poll
  /// at a quarter of it (see [_huntInterval]) so the game window is locked
  /// within ~½ s of appearing — shrinking the black frames at match start
  /// (verified 2026-07-21: a League match hunt took 6 s to find the window at
  /// a 2 s cadence, black until then) — then relaxing so a game that never
  /// surfaces a window doesn't poll fast for its whole session.
  /// Injectable so tests don't sleep for real seconds.
  final Duration autoSwitchRetryInterval;

  /// How many opening hunt attempts poll at the fast cadence (a quarter of
  /// [autoSwitchRetryInterval]) before relaxing to the steady interval.
  static const _fastHuntAttempts = 8;

  /// The wait before the next hunt attempt: fast for the opening burst (to
  /// catch the game window the instant the loading screen yields it), then
  /// the steady [autoSwitchRetryInterval]. Scales with the configured value
  /// so an injected tiny test interval stays tiny.
  Duration _huntInterval(int attempt) => attempt <= _fastHuntAttempts
      ? autoSwitchRetryInterval ~/ 4
      : autoSwitchRetryInterval;

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

  /// GameIds whose current session was RESUMED onto an older match by
  /// [_sessionStampFor] rather than started fresh, pending confirmation from
  /// the first [GameEventKind.matchInfo] that it really is the same match —
  /// see [_recordMatchInfo]. Cleared once that arrives (either way) and on
  /// deactivation.
  final Set<String> _unconfirmedResumes = {};

  /// How far the session's stamp may sit from the match start a source
  /// reports before [_recordMatchInfo] treats them as different matches.
  /// Wide enough to absorb poll-time sampling of League's `gameTime` and the
  /// gap between a match going live and its first `matchInfo`; far narrower
  /// than the time between two consecutive matches.
  static const matchIdentityWindow = Duration(minutes: 3);

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
    _unconfirmedResumes.add(a.gameId);
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
        // Full-session recording (opt-in per game): record the whole play
        // session to one file alongside the buffer. Gated on countsAsPlaying
        // so a launcher/client activation (League's client) doesn't record a
        // lobby as a "session".
        if (a.countsAsPlaying) _maybeStartAutoSession(a.gameId);
      } else {
        // Stop+index a full-session recording this game started, BEFORE the
        // session stamp is cleared below (the VOD must carry it to group with
        // the match's clips). Fire-and-forget: stopRecording + indexing is
        // slow/async and must not block this synchronous handler.
        final sessionAt = _sessionStartedAt[a.gameId];
        unawaited(_stopAutoSessionFor(a.gameId, sessionAt));
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
        _unconfirmedResumes.remove(a.gameId);
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
      // Match end (win/loss) — record the outcome onto the session's
      // MatchStats for the W/L badge. NOT a return: victory/defeat are also
      // in the settings event matrix (the "MATCH" group), so if the user
      // enabled them the normal auto-clip path below still saves the
      // victory/defeat moment. Outcome is recorded either way.
      if (e.kind == GameEventKind.victory || e.kind == GameEventKind.defeat) {
        _recordOutcome(e);
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
  ///
  /// The loop does not stop once a target is found — it keeps re-resolving
  /// and re-binds whenever the answer CHANGES. A one-shot bind goes stale:
  /// native League swaps in a new display-covering window between loading
  /// screen and gameplay, and SCK window capture of the abandoned one emits
  /// pure black for the rest of the match (verified live 2026-07-24).
  void _autoSwitchCaptureFor(GameActivity a) {
    _cancelAutoSwitchRetry(a.gameId);
    // `fresh: true` — an ACTIVATION may take the aim from another game that
    // is already playing (the game you just launched is the one you are
    // about to play). Its retry loop may not: that distinction is what turns
    // "the newest game wins" into a single switch instead of two loops
    // trading the aim every tick.
    _tryAutoSwitch(a, attempt: 1, fresh: true);
  }

  /// Whether [a]'s loop is allowed to bind the capture target right now.
  ///
  /// A launcher/client-only activation (countsAsPlaying false) must never
  /// STEAL the capture target from its own game's match-live binding.
  /// Normally the client activates first and the vendor watcher re-aims
  /// second, so ordering hides this — but an app (re)start MID-MATCH races
  /// both activations in the same tick, and the client won by 80 ms in a
  /// live match (2026-07-19 19:14), stomping the game window with the
  /// hidden client app and recording black again. The reverse direction
  /// (vendor re-aim overriding the client's earlier switch) stays allowed.
  ///
  /// Checked on EVERY tick, not just at activation: League's client and
  /// its match watcher are separate merged game ids, so each runs its own
  /// supervision loop, and once those loops stopped terminating on a
  /// successful bind the two re-aimed over each other every couple of
  /// seconds — a live match rebound the SCK stream 60 times in 90 s
  /// (2026-07-24 19:37). The client's loop stays alive but idle while its
  /// sibling holds the aim, and takes over again once the match ends and
  /// [_revertAutoSwitchFor] releases it.
  ///
  /// The same trade happens ACROSS games, which the merged-id rule alone did
  /// not cover: with Big Walk being played and League's client merely open,
  /// the two loops re-aimed over each other nine times in three seconds
  /// (2026-08-08 10:50:24-27), rebuilding the ScreenCaptureKit stream every
  /// time — libobs rejected half of them outright ("Invalid target window
  /// ID: 16780", the client's dead window). A capture source torn down and
  /// rebuilt mid-recording is heard as a glitch and seen as a hitch.
  bool _mayAim(GameActivity a, {required bool fresh}) {
    final holder = _autoSwitchedGameId;
    if (holder == null || holder == a.gameId) return true;

    // Nothing quietly takes the aim from a game that is currently being
    // PLAYED. Two exceptions, in order:
    //   - a launcher (countsAsPlaying false) never may, even on activation;
    //   - a real game may, but only on its own ACTIVATION (`fresh`), so the
    //     game you just launched wins once and then holds it.
    if (playingGameIds.value.contains(holder)) {
      return a.countsAsPlaying && fresh;
    }
    if (a.countsAsPlaying) return true;

    // The holder is not being played (a launcher holds it): the merged-id
    // rule decides. A client may not stomp its OWN game's live match.
    return !descriptorFor(a.gameId).mergedGameIds.contains(holder);
  }

  /// One attempt of [_autoSwitchCaptureFor]'s loop. [attempt] is 1-based and
  /// only drives the hunt cadence ([_huntInterval]); the loop itself runs
  /// until the game deactivates, whether or not a target was found, so a
  /// window the game replaces mid-match is re-aimed rather than left stale.
  void _tryAutoSwitch(GameActivity a,
      {required int attempt, bool fresh = false}) {
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
      _scheduleAutoSwitch(a, attempt: attempt);
      return;
    }
    _scheduleAutoSwitch(a, attempt: attempt);
    if (!_mayAim(a, fresh: fresh)) return;

    // A FULLSCREEN match is captured as its DISPLAY. Its window covers the
    // whole screen, so the display's content is exactly the game — and it is
    // the only route that actually delivers frames for one: SCK app capture
    // composites onto one anchor display and records black (2026-07-19), and
    // SCK window capture of native League's fullscreen window records black
    // too (verified live 2026-07-24 mid-match — while display capture in the
    // very same seconds of the same clip recorded real frames).
    //
    // Deliberately NOT gated on [AppInfo.onScreen]: `kCGWindowIsOnscreen` is
    // false whenever the game's Space isn't the active one, and a fullscreen
    // game always has its own Space. Requiring it made a live match fall
    // straight back out of display capture (2026-07-24 19:59:58).
    final fullscreen = match.displayUuid.isNotEmpty;

    // Nothing changed since the last bind — re-issuing the same target would
    // rebuild the SCK stream for nothing (and a target the user picked by
    // hand mid-game is left alone for the same reason).
    final target = fullscreen
        ? 'd:${match.displayUuid}'
        : match.windowId != 0 && (match.onScreen || match.bundleId.isEmpty)
            ? 'w:${match.windowId}'
            : 'a:${match.bundleId}';
    if (target == _autoSwitchedTarget && _autoSwitchedGameId == a.gameId) {
      return;
    }

    // Never DOWNGRADE a live binding to app capture. SCK app capture
    // composites onto one anchor display and is the route every black-clip
    // investigation has ended at; a game that momentarily stops reporting a
    // covering or on-screen window (moved, resized, alt-tabbed) must keep
    // the display/window target that was working, not fall back to it.
    final held = _autoSwitchedTarget;
    if (target.startsWith('a:') &&
        _autoSwitchedGameId == a.gameId &&
        held != null &&
        !held.startsWith('a:')) {
      return;
    }
    _autoSwitchedTarget = target;

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
    if (fullscreen) {
      capture.setCaptureDisplay(match.displayUuid);
      // Clears any window id AND the app target, leaving the display route
      // selected — see `rewind_set_capture_app`'s doc in the shim.
      capture.setCaptureApp(null);
    } else if (match.windowId != 0 &&
        (match.onScreen || match.bundleId.isEmpty)) {
      capture.setCaptureWindow(match.windowId);
    } else {
      capture.setCaptureApp(match.bundleId.isEmpty ? null : match.bundleId);
    }
    _autoSwitchedGameId = a.gameId;
    autoSwitchedAppName.value = match.name;
    talker.info('Auto-switched capture to ${match.name} ($target)');

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

  /// Books the next [_tryAutoSwitch] tick for [a], replacing any tick
  /// already pending for that game. Runs whether or not this attempt found
  /// a target: the loop is the game's aim supervision, not just its hunt.
  void _scheduleAutoSwitch(GameActivity a, {required int attempt}) {
    _autoSwitchRetryTimers.remove(a.gameId)?.cancel();
    _autoSwitchRetryTimers[a.gameId] = Timer(_huntInterval(attempt), () {
      _autoSwitchRetryTimers.remove(a.gameId);
      _tryAutoSwitch(a, attempt: attempt + 1);
    });
  }

  /// Cancels [gameId]'s pending [_autoSwitchCaptureFor] tick, if any —
  /// called on a fresh activation superseding an older loop, the game's
  /// deactivation, and [dispose].
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
    _autoSwitchedTarget = 'w:${app.windowId}';
    autoSwitchedAppName.value = app.name;
    talker.info('Capturing ${app.name} (window ${app.windowId})');
  }

  /// Reverts an auto-switch made by [_autoSwitchCaptureFor], but only when
  /// the deactivating game [a] is the one we switched for — an unrelated
  /// game exiting must not clobber the still-running game's capture target.
  void _revertAutoSwitchFor(GameActivity a) {
    if (_autoSwitchedGameId != a.gameId) return;
    _autoSwitchedGameId = null;
    _autoSwitchedTarget = null;
    autoSwitchedAppName.value = null;
    // A fullscreen auto-switch also moved the capture DISPLAY (see
    // [_tryAutoSwitch]); put the user's persisted choice back before the
    // app/display route is re-selected below.
    final savedDisplay = settings.captureDisplayUuid;
    if (savedDisplay != null) engine?.setCaptureDisplay(savedDisplay);
    engine?.setCaptureApp(settings.captureAppBundleId);
    talker.info('Reverted capture after ${a.displayName} exited');
  }

  /// Cancels pending burst timers without flushing. For tests — in the app
  /// the coordinator lives as long as the process, and shutdown-with-a-
  /// pending-burst is covered by the deactivation flush.
  void dispose() {
    lastSaveNotice.dispose();
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
    final gameId = _manualGameId;
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

  /// Which game a MANUAL capture (hotkey, "Save clip", a manual recording)
  /// belongs to.
  ///
  /// Not simply [activeGame]: that is whichever game activated most
  /// recently, and a game can detect as several merged ids — League's client
  /// (`app:league_of_legends`) alongside its live match
  /// (`league_of_legends`). When the client activates last, every manual
  /// clip taken mid-match was filed under the CLIENT, carrying the client's
  /// activation stamp instead of the match's, so it sat in its own group
  /// instead of with the match it came from (observed live 2026-07-24: four
  /// manual clips, all on `app:league_of_legends`). Prefer the id that
  /// counts as actually PLAYING, and only ever swap to a sibling of the
  /// active game — never to some unrelated game that happens to be running.
  String get _manualGameId {
    final active = activeGame.value;
    if (active == null) return 'desktop';
    final playing = playingGameIds.value;
    if (playing.contains(active)) return active;
    final merged = descriptorFor(active).mergedGameIds;
    for (final id in playing) {
      if (merged.contains(id)) return id;
    }
    return active;
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
        // Whatever libobs has to say about this is the actual explanation —
        // pull it now so it sits beside the failure rather than up to a perf
        // tick later.
        forwardObsLog(capture);
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

    final gameId = _manualGameId;
    // The recording's kill count spans its whole session, not the buffer
    // window — grab the start before clearing it below.
    final startedAt = recordingStartedAt.value;
    // The engine-side session ends with this call either way (success or
    // failure) — clear local state up front so a failed save below doesn't
    // leave the deck stuck showing "recording".
    isRecording.value = false;
    recordingStartedAt.value = null;
    // If this manual stop is ending a full-session recording the user chose
    // to cut short, drop the auto flag so the eventual game exit doesn't try
    // to stop an already-stopped slot.
    _autoSessionGameId = null;
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

  /// The game whose full play session is being auto-recorded (see
  /// [GameConfig.recordFullSession]), or null. Distinct from a manual
  /// recording so a game exit only stops what a game activation started —
  /// never a manual recording — and a manual stop of the auto-session
  /// (the user overriding) clears it so the exit doesn't double-stop.
  String? _autoSessionGameId;

  /// Starts a full-session recording for [gameId] when the game opts in and
  /// nothing is already recording. Shares the single shim recording slot and
  /// [isRecording] state with manual recording, so a manual recording in
  /// progress (or another game's session) simply blocks this — no double
  /// start. The rolling buffer keeps running regardless.
  void _maybeStartAutoSession(String gameId) {
    final capture = engine;
    if (capture == null) return;
    if (!settings.configFor(gameId).recordFullSession) return;
    if (isRecording.value || _togglingRecording) return; // slot busy
    try {
      if (!capture.startRecording(outDir)) {
        talker.error('Full-session recording failed to start: '
            '${capture.lastError}');
        return;
      }
      isRecording.value = true;
      recordingStartedAt.value = DateTime.now();
      _autoSessionGameId = gameId;
      talker.info('Full-session recording started for $gameId');
    } catch (err, stack) {
      talker.handle(err, stack);
    }
  }

  /// Stops and indexes the auto-session ONLY if it belongs to [gameId] (its
  /// game exited). [sessionAt] is the match stamp captured before it was
  /// cleared, so the session VOD groups with the match's other clips.
  Future<void> _stopAutoSessionFor(String gameId, DateTime? sessionAt) async {
    if (_autoSessionGameId != gameId) return;
    final capture = engine;
    if (capture == null) return;
    final startedAt = recordingStartedAt.value;
    _autoSessionGameId = null;
    isRecording.value = false;
    recordingStartedAt.value = null;
    try {
      final path = capture.stopRecording();
      if (path == null) {
        talker.error('Full-session recording save failed: '
            '${capture.lastError}');
        return;
      }
      talker.info('Full-session recording saved for $gameId');
      await _indexClip(
          path, GameEvent(gameId: gameId, kind: GameEventKind.recording),
          windowStart: startedAt, sessionAt: sessionAt);
    } catch (err, stack) {
      talker.handle(err, stack);
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
    var sessionStart = _sessionStartedAt[e.gameId];
    final stats = matchStats;
    if (sessionStart == null || stats == null) return;
    final champion = e.meta['champion'] as String?;

    // The session stamp so far is a GUESS: either this activation's clock
    // time, or — after a restart — the previous match's stamp, resumed on
    // nothing more than "its stats were moving recently" ([_sessionStampFor]).
    // A source that reports when the match ACTUALLY began (League derives it
    // from the Live Client Data API's `gameTime`, which resets every match)
    // settles it outright: keep the current stamp when it's the same match,
    // otherwise re-key to the reported start.
    //
    // This is what separates two consecutive matches ON THE SAME CHAMPION,
    // which the champion comparison below cannot see. Without it a stale
    // resume merges them into one card — the earlier match's champion
    // overwritten, both scorelines summed, its card gone (observed live
    // 2026-07-24: a Singed match started 19:14 was consumed by the Master Yi
    // match that started 19:37).
    final reportedStart =
        DateTime.tryParse(e.meta['matchStartedAt'] as String? ?? '');
    if (reportedStart != null) {
      _unconfirmedResumes.remove(e.gameId);
      // Tolerance, not equality: `gameTime` is sampled at poll time, so the
      // same match resolves a second or two apart across restarts, while a
      // genuinely new match is a whole match-length away.
      if (sessionStart.difference(reportedStart).abs() > matchIdentityWindow) {
        talker.info('Match start reported as '
            '${reportedStart.toIso8601String()} — re-keying the session from '
            '${sessionStart.toIso8601String()}');
        sessionStart = reportedStart;
        _sessionStartedAt[e.gameId] = sessionStart;
      }
    } else if (_unconfirmedResumes.remove(e.gameId) && champion != null) {
      final resumed = stats.statsFor(e.gameId, sessionStart);
      final was = resumed?.champion;
      if (was != null && was != champion) {
        sessionStart = DateTime.now();
        _sessionStartedAt[e.gameId] = sessionStart;
        talker.info('Resumed session was a DIFFERENT match ($was, not '
            '$champion) — starting a fresh one at '
            '${sessionStart.toIso8601String()}');
      }
    }

    stats.recordMatchInfo(
      e.gameId,
      sessionStart,
      gameMode: e.meta['gameMode'] as String?,
      champion: champion,
      allies: _parsePlayers(e.meta['allies']),
      enemies: _parsePlayers(e.meta['enemies']),
      rawChampionName: e.meta['rawChampionName'] as String?,
      skinName: e.meta['skinName'] as String?,
    );
  }

  void _recordOutcome(GameEvent e) {
    final stats = matchStats;
    if (stats == null) return;
    final result =
        e.kind == GameEventKind.victory ? MatchResult.win : MatchResult.loss;
    final sessionStart = _sessionStartedAt[e.gameId];
    if (sessionStart == null) {
      // The other way an outcome can vanish: GameEnd arrives after the game
      // already deactivated, so there is no live session to key it to. Fall
      // back to the most recently touched match for this game — an outcome
      // only ever arrives at the END of a match, so "the one that just
      // finished" is the correct target — but only if it was touched
      // recently, so a GameEnd from a stale/replayed event log can't stamp a
      // result onto a match from days ago.
      final latest = stats.latestFor(e.gameId);
      if (latest == null ||
          DateTime.now().difference(latest.updatedAt) >
              const Duration(hours: 3)) {
        talker.warning('League: match ${result.name} arrived with no live '
            'session and no recent match to attach it to — outcome dropped');
        return;
      }
      talker.info('Match ${result.name} arrived after the session ended — '
          'recording it on the match that started ${latest.startedAt}');
      stats.recordOutcome(e.gameId, latest.startedAt, result);
      return;
    }
    stats.recordOutcome(e.gameId, sessionStart, result);
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
      {DateTime? windowStart, DateTime? sessionAt}) async {
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
      // Explicit override for a full-session VOD, whose match stamp was
      // captured before deactivation cleared it; every other caller lets the
      // live session map answer.
      sessionAt: sessionAt ?? _sessionStartedAt[e.gameId],
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
    if (e.kind == GameEventKind.manual) {
      lastManualSave.value = null;
      lastManualSave.value = clip;
    }
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
    // Decide BEFORE reporting. ValueNotifier notifies synchronously, so
    // setting lastSaveError first and clearing it inside
    // _recoverIfBufferDied still pushed a red "Couldn't save clip: buffer
    // not running" SnackBar onto the screen, immediately followed by the
    // calm explanation — which reads worse than either message alone.
    if (_isDeliberatelyPaused(msg)) {
      talker.info(
          'Nothing to save: the replay buffer is paused (see "Only record '
          'while playing", or the tray\'s Pause). Not restarting it.');
      lastSaveNotice.value = null;
      lastSaveNotice.value =
          'Nothing to clip yet — Rewind only records while a game is running, '
          'so the last few seconds were not being kept. It starts by itself '
          'when a game is detected, or turn off "Only record while playing" '
          'in Settings to record all the time.';
      return;
    }
    lastSaveError.value = null;
    lastSaveError.value = msg;
    _recoverIfBufferDied(msg);
  }

  /// A save that failed only because the buffer was stopped ON PURPOSE —
  /// "only record while playing" with no game up, or a manual tray pause.
  /// Both surface the same "buffer not running" from the shim as a buffer
  /// that died on its own, and only [bufferShouldBeRunning] separates them.
  bool _isDeliberatelyPaused(String msg) =>
      msg.toLowerCase().contains('buffer not running') &&
      bufferShouldBeRunning?.value == false;

  /// libobs can stop the replay output underneath us — the capture source
  /// breaking, or another screen-capture client taking over — and it tells
  /// nobody. Before this, the ONLY symptom was `saveClip` returning "buffer
  /// not running", logged once per lost clip and invisible in the UI: the
  /// recorder chip went on reading ARMED, the tray went on reading armed, and
  /// an entire evening's clips were silently dropped (observed 2026-07-26,
  /// eight consecutive kills across three matches, none saved).
  ///
  /// So: say it loudly, stop the UI claiming to be armed, and try once to
  /// bring the buffer back rather than making the user notice and restart the
  /// app. A failed restart leaves [captureDown] set, which is what the
  /// recorder chip reads to show UNAVAILABLE.
  void _recoverIfBufferDied(String msg) {
    if (!msg.toLowerCase().contains('buffer not running')) return;
    final capture = engine;
    if (capture == null) return;

    // A buffer that is stopped ON PURPOSE is not a failure. "Only record
    // while playing" with no game up, or a manual tray pause, both land
    // here with the same message from the shim — and restarting in that
    // case defeats the very setting the user chose.
    // Reached only by callers other than _reportSaveError, which now
    // filters this case out before anything is reported.
    if (bufferShouldBeRunning?.value == false) {
      talker.info('Replay buffer is paused on purpose; not restarting it.');
      return;
    }

    talker.error(
        'Replay buffer stopped without notice — a clip was lost. Restarting '
        'it now; if this repeats, the capture source is the thing to look at.');
    // The lines libobs emitted when the output died are the whole reason this
    // path is guesswork otherwise.
    forwardObsLog(capture);
    captureDown.value = true;

    final restarted = capture.startBuffer();
    if (restarted) {
      captureDown.value = false;
      talker.warning('Replay buffer restarted. The clip that triggered this '
          'is gone, but capture is live again.');
    } else {
      talker.error('Replay buffer would NOT restart: ${capture.lastError}. '
          'Nothing is being captured until this is resolved.');
      forwardObsLog(capture);
    }
  }
}
