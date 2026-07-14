/// A notable in-game moment that may warrant saving a clip.
///
/// Game integrations emit these; the [ClipCoordinator] decides whether the
/// user has enabled clipping for this [kind] and, if so, triggers a save.
enum GameEventKind {
  // Generic
  manual, // user pressed the hotkey
  // Combat
  kill,
  doubleKill,
  tripleKill,
  quadraKill,
  pentaKill,
  ace,
  // Objectives (League-style, but reusable)
  dragonKill,
  dragonSteal,
  baronKill,
  baronSteal,
  turretKill,
  inhibitorKill,
  // Match flow
  victory,
  defeat,
  recording, // a manual recording session (deck button / record hotkey)
  other,
}

class GameEvent {
  final String gameId;
  final GameEventKind kind;
  final DateTime time;

  /// Optional free-form details from the source (raw event name, actor, etc.).
  final Map<String, dynamic> meta;

  GameEvent({
    required this.gameId,
    required this.kind,
    DateTime? time,
    this.meta = const {},
  }) : time = time ?? DateTime.now();

  @override
  String toString() => 'GameEvent($gameId, ${kind.name}, $time)';
}
