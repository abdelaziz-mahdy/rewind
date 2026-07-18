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

  /// Whether this source activating means the user is actually PLAYING —
  /// the signal `ClipCoordinator.playingGameIds` (and, through it, the
  /// `captureOnlyInGame` buffer policy) narrows down to, as opposed to
  /// [GameActivity]/`activeGameIds`' broader "detected at all" (which still
  /// covers e.g. a game's launcher/client being open). True for almost every
  /// source — the process the source detects generally IS the game. False
  /// only where detection fires on something short of gameplay, e.g. the
  /// League client catalog entry (see `game_catalog.dart`), which is running
  /// throughout lobby/champ-select/post-game, not just while a match is
  /// live.
  bool get countsAsPlaying => true;
}
