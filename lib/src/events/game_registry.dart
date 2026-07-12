import 'dart:async';

import 'game_event.dart';
import 'game_event_source.dart';
import 'league_event_watcher.dart';

/// Holds all known game integrations and supervises which are active.
///
/// A supervisor loop polls each source's [GameEventSource.isGameRunning]. When
/// a game becomes active the source is started and its events are merged into
/// [events]. Multiple sources may be active simultaneously (cross-game).
class GameRegistry {
  final List<GameEventSource> _sources;
  final _merged = StreamController<GameEvent>.broadcast();
  final Set<String> _active = {};
  Timer? _supervisor;

  GameRegistry({List<GameEventSource>? sources})
      : _sources = sources ??
            [
              LeagueEventWatcher(),
              // Register additional GameEventSource implementations here.
            ];

  Stream<GameEvent> get events => _merged.stream;

  Iterable<GameEventSource> get sources => _sources;

  void startSupervising() {
    _supervisor ??=
        Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  Future<void> _tick() async {
    for (final s in _sources) {
      final running = await s.isGameRunning();
      if (running && !_active.contains(s.gameId)) {
        _active.add(s.gameId);
        await s.start();
        s.events().listen(_merged.add);
      } else if (!running && _active.contains(s.gameId)) {
        _active.remove(s.gameId);
        await s.stop();
      }
    }
  }

  Future<void> dispose() async {
    _supervisor?.cancel();
    for (final s in _sources) {
      await s.stop();
    }
    await _merged.close();
  }
}
