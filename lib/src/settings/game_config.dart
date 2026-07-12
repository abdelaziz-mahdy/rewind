import '../events/game_event.dart';

/// Per-game configuration. Each game can have its own replay-buffer length,
/// its own set of auto-clipped events, and whether auto-clipping is on.
class GameConfig {
  final String gameId;

  /// Replay-buffer length in seconds for this game (e.g. 30 or 60).
  int bufferSeconds;

  /// Whether to auto-clip on detected events (vs. hotkey-only).
  bool autoClip;

  /// Event kinds to auto-clip for this game.
  Set<GameEventKind> enabledEvents;

  GameConfig({
    required this.gameId,
    this.bufferSeconds = 30,
    this.autoClip = true,
    Set<GameEventKind>? enabledEvents,
  }) : enabledEvents = enabledEvents ??
            {
              GameEventKind.manual,
              GameEventKind.kill,
              GameEventKind.doubleKill,
              GameEventKind.tripleKill,
              GameEventKind.quadraKill,
              GameEventKind.pentaKill,
              GameEventKind.ace,
            };

  Map<String, dynamic> toJson() => {
        'gameId': gameId,
        'bufferSeconds': bufferSeconds,
        'autoClip': autoClip,
        'enabledEvents': enabledEvents.map((e) => e.name).toList(),
      };

  factory GameConfig.fromJson(Map<String, dynamic> j) => GameConfig(
        gameId: j['gameId'] as String,
        bufferSeconds: j['bufferSeconds'] as int? ?? 30,
        autoClip: j['autoClip'] as bool? ?? true,
        enabledEvents: ((j['enabledEvents'] as List?) ?? const [])
            .map((n) => GameEventKind.values.firstWhere((e) => e.name == n,
                orElse: () => GameEventKind.other))
            .toSet(),
      );
}
