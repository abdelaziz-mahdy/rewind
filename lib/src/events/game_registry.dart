import 'dart:async';

import 'game_event.dart';
import 'game_event_source.dart';
import 'league_event_watcher.dart';
import 'process_watcher_source.dart';

/// A game becoming active or inactive (auto-detection result).
class GameActivity {
  final String gameId;
  final String displayName;
  final bool active;

  /// The OS process-name substring that identified this game, when the
  /// source is a [ProcessWatcherSource] (populated in [GameRegistry._tick]).
  /// Null for vendor-API sources like League, which have no OS process to
  /// match — the coordinator uses this to find the game's running
  /// app/window for auto-switching the capture target; see
  /// `ClipCoordinator`. Not set on deactivation (not needed for reverts).
  final String? processMatch;

  GameActivity(this.gameId, this.displayName, this.active, {this.processMatch});
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
            ];

  Stream<GameEvent> get events => _merged.stream;
  Stream<GameActivity> get activity => _activity.stream;
  Iterable<GameEventSource> get sources => _sources;
  Set<String> get activeGameIds => Set.unmodifiable(_active);

  void startSupervising({Duration interval = const Duration(seconds: 3)}) {
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
      if (have.add(c.gameId)) _sources.add(c);
    }
  }

  Future<void> _tick() async {
    for (final s in _sources) {
      final running = await s.isGameRunning();
      if (running && !_active.contains(s.gameId)) {
        _active.add(s.gameId);
        await s.start();
        s.events().listen(_merged.add);
        _activity.add(GameActivity(
          s.gameId,
          s.displayName,
          true,
          processMatch: s is ProcessWatcherSource ? s.processMatch : null,
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
