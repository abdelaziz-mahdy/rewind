import '../events/game_event.dart';

/// A saved clip on disk plus its metadata.
class Clip {
  final String path;
  final String gameId;
  final GameEventKind event;
  final DateTime createdAt;
  final int sizeBytes;

  /// Pinned/protected clips are NEVER auto-deleted by [StorageManager].
  bool protected;

  /// When the game session (match) this clip belongs to began — the game's
  /// activation time as recorded by `ClipCoordinator` at save time, shared
  /// by every clip of the same match so hubs can group them. Null for clips
  /// saved with no game active (desktop/manual) and clips from older
  /// versions; grouping then falls back to time-gap clustering (see
  /// `lib/src/ui/clip_sessions.dart`).
  final DateTime? sessionAt;

  Clip({
    required this.path,
    required this.gameId,
    required this.event,
    required this.createdAt,
    required this.sizeBytes,
    this.protected = false,
    this.sessionAt,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'gameId': gameId,
        'event': event.name,
        'createdAt': createdAt.toIso8601String(),
        'sizeBytes': sizeBytes,
        'protected': protected,
        'sessionAt': sessionAt?.toIso8601String(),
      };

  factory Clip.fromJson(Map<String, dynamic> j) => Clip(
        path: j['path'] as String,
        gameId: j['gameId'] as String,
        event: GameEventKind.values.firstWhere((e) => e.name == j['event'],
            orElse: () => GameEventKind.other),
        createdAt: DateTime.parse(j['createdAt'] as String),
        sizeBytes: j['sizeBytes'] as int,
        protected: j['protected'] as bool? ?? false,
        sessionAt: j['sessionAt'] != null
            ? DateTime.parse(j['sessionAt'] as String)
            : null,
      );
}
