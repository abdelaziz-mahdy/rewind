import '../events/game_event.dart';

/// A saved clip on disk plus its metadata.
/// Where a clip's video came from — see [Clip.origin].
enum ClipOrigin {
  /// Recorded live by the capture engine.
  captured,

  /// A time range of another clip (the player's Trim).
  trimmed,

  /// A whole session concatenated into one video (a match's "Export as one
  /// video").
  exported,
}

/// Reads [Clip.origin] from stored JSON, inferring it for clips written
/// before the field existed: their eventLabel is the only trace, and the two
/// derived kinds each wrote a fixed one.
ClipOrigin _originFrom(Map<String, dynamic> j) {
  final stored = j['origin'] as String?;
  if (stored != null) {
    for (final o in ClipOrigin.values) {
      if (o.name == stored) return o;
    }
  }
  final byLabel = switch (j['eventLabel'] as String?) {
    'Full match' => ClipOrigin.exported,
    'Trimmed' => ClipOrigin.trimmed,
    _ => null,
  };
  if (byLabel != null) return byLabel;

  // Last resort, the file name. An export written before ANY marker existed
  // was adopted by the library's stray-file scan as a plain manual clip,
  // with no label to read — and one such 764 MB file was still sitting in a
  // session, ready to be swallowed by the next export of it. Both derived
  // paths have always named their output this way.
  final name = (j['path'] as String? ?? '').split('/').last;
  if (name.contains('-full-match')) return ClipOrigin.exported;
  if (name.contains('-trim-')) return ClipOrigin.trimmed;
  return ClipOrigin.captured;
}

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

  /// How many of the player's kills fall inside this clip's footage window
  /// (the buffer length before an event save, or the whole session for a
  /// manual recording) — counted by `ClipCoordinator` from the live event
  /// stream at save time. 0 when nothing was counted (desktop clips, games
  /// without an event API, older clips).
  final int killCount;

  /// A per-instance label for [event], for kinds where the generic
  /// [event]-derived badge text ("ACHIEVEMENT") alone would lose the
  /// specific thing that happened — currently only Steam achievement
  /// unlocks, whose real display name (e.g. "Speed Run Master") comes from
  /// `SteamAchievementWatcher`'s `GameEvent.meta['label']` and is threaded
  /// through by `ClipCoordinator._indexClip`. Null for every other event
  /// kind and for clips saved before this field existed.
  final String? eventLabel;

  /// Where this video came from: captured live, or DERIVED from clips that
  /// already exist.
  ///
  /// Not inferable from [eventLabel] — that already carries an achievement's
  /// real name ("Big Pack"), so "has a label" cannot mean "is derived".
  ///
  /// The distinction is load-bearing, not cosmetic: "Export as one video"
  /// concatenates a session's clips, and once an export was itself indexed
  /// into that session, the NEXT export swallowed it — 43 MB of clips became
  /// a 258 MB export, then a 516 MB one. Derived videos are excluded from
  /// anything that treats a session as source footage.
  final ClipOrigin origin;

  /// How long the video runs, once known. Null for a clip recorded before
  /// this field existed, or one whose file could not be read.
  ///
  /// Shown BEFORE the file size on every tile: "how long is this" is the
  /// question someone actually has when picking a clip to watch, and the
  /// size only matters when they are clearing space.
  int? durationMs;

  Clip({
    required this.path,
    required this.gameId,
    required this.event,
    required this.createdAt,
    required this.sizeBytes,
    this.protected = false,
    this.sessionAt,
    this.killCount = 0,
    this.eventLabel,
    this.origin = ClipOrigin.captured,
    this.durationMs,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'gameId': gameId,
        'event': event.name,
        'createdAt': createdAt.toIso8601String(),
        'sizeBytes': sizeBytes,
        'protected': protected,
        'sessionAt': sessionAt?.toIso8601String(),
        'killCount': killCount,
        'eventLabel': eventLabel,
        'origin': origin.name,
        'durationMs': durationMs,
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
        killCount: j['killCount'] as int? ?? 0,
        eventLabel: j['eventLabel'] as String?,
        origin: _originFrom(j),
        durationMs: (j['durationMs'] as num?)?.toInt(),
      );
}
