import 'game_event.dart';

/// The single interface every game integration implements.
///
/// Adding support for a new game means writing one of these and registering it
/// in [GameRegistry]. Integrations MUST NOT touch the capture engine — they
/// only detect the game and emit [GameEvent]s.
abstract class GameEventSource {
  /// Stable id, e.g. "league_of_legends".
  String get gameId;

  /// Human-readable name for the UI.
  String get displayName;

  /// Cheap probe: is this game currently running / its local API reachable?
  Future<bool> isGameRunning();

  /// Stream of events while the game is active.
  Stream<GameEvent> events();

  /// Begin watching (called when [isGameRunning] first returns true).
  Future<void> start();

  /// Stop watching and release resources.
  Future<void> stop();
}
