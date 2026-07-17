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
  death, // the player died — never auto-clipped, but counted for match K/D
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
  // Not a clip trigger: carries per-match metadata (champion, teams, mode)
  // in [GameEvent.meta] for the coordinator to record onto MatchStats.
  matchInfo,
  // Not a clip trigger: carries a fresh snapshot of the active player's
  // live stats (assists, creep score, ward score, current items) in
  // [GameEvent.meta] — unlike [matchInfo] (captured once, stable for the
  // whole match), this is emitted on every poll since those numbers keep
  // changing. See `LeagueEventWatcher._emitStatsUpdate`.
  statsUpdate,
  other,
}

/// Ranks event kinds by clip-worthiness, higher = better. When a burst of
/// events collapses into ONE clip (see `ClipCoordinator`'s burst debounce),
/// the clip is labeled with the burst's highest-ranked kind — a penta kill
/// must never be badged as a plain "KILL" because the penta came second.
int clipPriority(GameEventKind kind) => switch (kind) {
      GameEventKind.pentaKill => 100,
      GameEventKind.quadraKill => 90,
      GameEventKind.ace => 85,
      GameEventKind.tripleKill => 80,
      GameEventKind.doubleKill => 70,
      GameEventKind.baronSteal => 65,
      GameEventKind.dragonSteal => 60,
      GameEventKind.baronKill => 55,
      GameEventKind.dragonKill => 50,
      GameEventKind.kill => 40,
      GameEventKind.victory => 35,
      GameEventKind.defeat => 30,
      GameEventKind.turretKill => 25,
      GameEventKind.inhibitorKill => 20,
      GameEventKind.manual => 10,
      GameEventKind.recording => 10,
      // Deaths are counted for match K/D but never win a clip label — a
      // fight the player also got a kill in should badge the kill.
      GameEventKind.death => 5,
      GameEventKind.matchInfo => 0,
      GameEventKind.statsUpdate => 0,
      GameEventKind.other => 0,
    };

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
