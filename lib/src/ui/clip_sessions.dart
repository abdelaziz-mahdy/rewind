import '../clip/clip.dart';

/// One group of clips from the same play session (match): the unit the game
/// hubs' clip grids are sectioned by.
class ClipSession {
  /// When the session began — the shared [Clip.sessionAt] for stamped
  /// groups, else the oldest clip's timestamp for gap-clustered fallback
  /// groups.
  final DateTime startedAt;

  /// The session's clips, newest first.
  final List<Clip> clips;

  const ClipSession({required this.startedAt, required this.clips});
}

/// Groups [clips] into play sessions, newest session first.
///
/// Clips stamped with a [Clip.sessionAt] (saved by a coordinator that saw
/// the game activate) group exactly: one session per distinct stamp.
/// Unstamped clips (desktop/manual saves, clips from older versions) fall
/// back to time-gap clustering: sorted newest-first, a break wider than
/// [maxGap] between consecutive clips starts a new session. 30 minutes
/// separates back-to-back matches (queue + lobby time) without splitting a
/// quiet mid-game stretch.
List<ClipSession> groupClipsIntoSessions(
  List<Clip> clips, {
  Duration maxGap = const Duration(minutes: 30),
}) {
  final byStamp = <DateTime, List<Clip>>{};
  final unstamped = <Clip>[];
  for (final c in clips) {
    final stamp = c.sessionAt;
    if (stamp != null) {
      byStamp.putIfAbsent(stamp, () => []).add(c);
    } else {
      unstamped.add(c);
    }
  }

  final sessions = <ClipSession>[
    for (final entry in byStamp.entries)
      ClipSession(
        startedAt: entry.key,
        clips: entry.value..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
      ),
  ];

  unstamped.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  List<Clip>? current;
  for (final c in unstamped) {
    if (current == null ||
        current.last.createdAt.difference(c.createdAt) > maxGap) {
      current = [c];
      // startedAt is finalized below from the group's oldest clip.
      sessions.add(ClipSession(startedAt: c.createdAt, clips: current));
    } else {
      current.add(c);
    }
  }
  // A gap-clustered group's startedAt should be its OLDEST clip (the list
  // is built newest-first, so that's the last element).
  final finalized = [
    for (final s in sessions)
      ClipSession(
        startedAt: s.clips.isEmpty
            ? s.startedAt
            : (s.startedAt.isBefore(s.clips.last.createdAt)
                ? s.startedAt
                : s.clips.last.createdAt),
        clips: s.clips,
      ),
  ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return finalized;
}
