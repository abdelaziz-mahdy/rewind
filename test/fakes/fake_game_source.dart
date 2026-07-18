import 'dart:async';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_event_source.dart';

class FakeGameSource implements GameEventSource {
  @override
  final String gameId;
  @override
  final String displayName;
  @override
  final bool countsAsPlaying;
  @override
  final String? processMatch;
  bool running = false;
  final _events = StreamController<GameEvent>.broadcast();

  // Trailing positional-optional (not named — Dart forbids mixing `[]` and
  // `{}` optional params, and every call site already passes these
  // positionally): a fourth slot for the auto-switch needle, alongside the
  // existing display name / countsAsPlaying overrides.
  FakeGameSource(this.gameId,
      [String? name, this.countsAsPlaying = true, this.processMatch])
      : displayName = name ?? gameId;

  void emit(GameEventKind kind) =>
      _events.add(GameEvent(gameId: gameId, kind: kind));

  /// Emit a fully-formed event (e.g. a matchInfo carrying meta).
  void emitEvent(GameEvent event) => _events.add(event);

  @override
  Future<bool> isGameRunning() async => running;
  @override
  Stream<GameEvent> events() => _events.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
