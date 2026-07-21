import 'dart:async';

import 'game_event.dart';
import 'game_event_source.dart';
import 'league_event_watcher.dart';

/// A game becoming active or inactive (auto-detection result).
class GameActivity {
  final String gameId;
  final String displayName;
  final bool active;

  /// The source's [GameEventSource.processMatch], stamped on here so the
  /// coordinator can find this game's running app/window and auto-switch
  /// the capture target at it — see `ClipCoordinator._autoSwitchCaptureFor`.
  /// Null when the source has nothing meaningful to match (most vendor-API
  /// integrations don't need this — `LeagueEventWatcher` is the one that
  /// does, since its match-live activation must re-aim capture at the
  /// actual game process). Not set on deactivation (not needed for
  /// reverts).
  final String? processMatch;

  /// The source's [GameEventSource.countsAsPlaying], stamped on here so the
  /// coordinator can maintain `playingGameIds` alongside `activeGameIds`
  /// without reaching back into the registry's sources. Meaningless on
  /// deactivation (defaults true, but unused — removing a gameId from a set
  /// it was never added to is a no-op).
  final bool countsAsPlaying;

  GameActivity(this.gameId, this.displayName, this.active,
      {this.processMatch, this.countsAsPlaying = true});
}

/// Holds all known game integrations and supervises which are active.
///
/// A supervisor loop polls each source's [GameEventSource.isGameRunning]
/// (auto-detection). When a game becomes active the source is started and its
/// events are merged into [events]; activity transitions are published on
/// [activity] so the coordinator can apply that game's config. Multiple games
/// can be active at once (cross-game).
class GameRegistry {
  final List<GameEventSource> _sources;
  final _merged = StreamController<GameEvent>.broadcast();
  final _activity = StreamController<GameActivity>.broadcast();
  final Set<String> _active = {};
  Timer? _supervisor;

  GameRegistry({List<GameEventSource>? sources})
      : _sources = sources ??
            [
              LeagueEventWatcher(),
              // Register additional GameEventSource implementations here.
            ] {
    for (final s in _sources) {
      _mergeEventsOf(s);
    }
  }

  Stream<GameEvent> get events => _merged.stream;
  Stream<GameActivity> get activity => _activity.stream;
  Iterable<GameEventSource> get sources => _sources;
  Set<String> get activeGameIds => Set.unmodifiable(_active);

  /// Polls every source's `isGameRunning` on [interval]. 2 s (not 3) so a
  /// game's transitions — especially a mid-match app appearing, like League's
  /// GameClient that triggers the capture re-aim onto the on-screen game
  /// window — are detected ~1 s sooner, shrinking the black frames between the
  /// client hiding and the game window being captured. Detection is one
  /// shared, cached process-list read per tick ([CachingProcessLister]), so a
  /// tighter cadence is cheap.
  void startSupervising({Duration interval = const Duration(seconds: 2)}) {
    _supervisor ??= Timer.periodic(interval, (_) => _tick());
  }

  /// One supervision pass — used by tests and by [startSupervising].
  Future<void> tickNow() => _tick();

  /// Adopt any of [candidates] whose gameId isn't supervised yet — the live
  /// half of "add a game while the app is running" (picking an app from the
  /// capture-source menu, Supported Games' Add): the next supervision tick
  /// starts watching them, no restart needed. Existing sources are left
  /// untouched (their running state must survive), and removal is
  /// deliberately not handled — a deleted config's source just idles until
  /// the next launch rebuilds the list.
  void addNewSources(Iterable<GameEventSource> candidates) {
    final have = {for (final s in _sources) s.gameId};
    for (final c in candidates) {
      if (have.add(c.gameId)) {
        _sources.add(c);
        _mergeEventsOf(c);
      }
    }
  }

  /// Subscribes [s]'s [GameEventSource.events] into [_merged] the moment
  /// it's registered — NOT gated on [GameEventSource.isGameRunning] ever
  /// reporting true, unlike [start]/[stop]/[_active] below (those stay
  /// activation-driven, unchanged). Most sources only ever emit after
  /// [_tick] calls their [GameEventSource.start] anyway, so this changes
  /// nothing for them; it exists for a source whose activation model is
  /// entirely its own (e.g. `SteamStatsWatcher`/`SteamAchievementWatcher`, whose
  /// [GameEventSource.isGameRunning] always answers false — it drives no
  /// `activeGameIds`/capture-switch/buffer-policy signal at all — so this
  /// tick's activation branch would otherwise never wire its events up).
  /// Called exactly once per source (constructor + [addNewSources]); doing
  /// it again in [_tick]'s activation branch would double-subscribe and
  /// double-emit every event for every OTHER source.
  void _mergeEventsOf(GameEventSource s) => s.events().listen(_merged.add);

  Future<void> _tick() async {
    for (final s in _sources) {
      final running = await s.isGameRunning();
      if (running && !_active.contains(s.gameId)) {
        _active.add(s.gameId);
        await s.start();
        _activity.add(GameActivity(
          s.gameId,
          s.displayName,
          true,
          processMatch: s.processMatch,
          countsAsPlaying: s.countsAsPlaying,
        ));
      } else if (!running && _active.contains(s.gameId)) {
        _active.remove(s.gameId);
        await s.stop();
        _activity.add(GameActivity(s.gameId, s.displayName, false));
      }
    }
  }

  Future<void> dispose() async {
    _supervisor?.cancel();
    for (final s in _sources) {
      await s.stop();
    }
    await _merged.close();
    await _activity.close();
  }
}
