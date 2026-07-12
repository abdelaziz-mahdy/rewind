import 'dart:async';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_event_source.dart';

class FakeGameSource implements GameEventSource {
  @override
  final String gameId;
  @override
  final String displayName;
  bool running = false;
  final _events = StreamController<GameEvent>.broadcast();

  FakeGameSource(this.gameId, [String? name]) : displayName = name ?? gameId;

  void emit(GameEventKind kind) =>
      _events.add(GameEvent(gameId: gameId, kind: kind));

  @override
  Future<bool> isGameRunning() async => running;
  @override
  Stream<GameEvent> events() => _events.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
