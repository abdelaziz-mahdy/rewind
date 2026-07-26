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
///
/// Finally, a session that lies ENTIRELY INSIDE another session's time span
/// is absorbed into it (see [_absorbOverlapping]). A hotkey clip taken
/// during a match must appear in that match — it is the same play session by
/// every meaning the user has — and a stamp alone cannot guarantee that.
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
  return _absorbOverlapping(finalized);
}

/// Folds a session that sits entirely within another session's span into
/// that session.
///
/// A manual clip saved DURING a match is part of that match, and a user who
/// took one has no model in which it belongs somewhere else. The coordinator
/// tries to stamp it with the match's session (see
/// `ClipCoordinator._manualGameId`), but that can only ever work when the
/// match is the id it resolves to at that instant — and a real library
/// (2026-07-24) shows what happens when it isn't: three manual clips saved
/// mid-match each became their own one-clip "session", stranded beside the
/// match they came from. Older clips saved before that fix existed are
/// stranded permanently, since a stored stamp is never rewritten.
///
/// Grouping by TIME as well as by stamp fixes both: the live case defensively,
/// the historical case retroactively, without touching a single stored clip.
///
/// Strictly containment, not proximity: a clip must fall inside the host's
/// first-to-last span (plus [_absorbGrace] at each end, for a clip saved a
/// moment before the first event or after the last). Two adjacent matches
/// therefore never merge — neither contains the other.
List<ClipSession> _absorbOverlapping(List<ClipSession> sessions) {
  if (sessions.length < 2) return sessions;

  DateTime endOf(ClipSession s) => s.clips.first.createdAt; // newest first

  // Hosts first: only a session with more than one clip can absorb, so a
  // lone manual can never swallow a match.
  final hosts = sessions.where((s) => s.clips.length > 1).toList();
  if (hosts.isEmpty) return sessions;

  final absorbed = <ClipSession>{};
  final merged = <ClipSession, List<Clip>>{};
  for (final s in sessions) {
    if (s.clips.length > 1) continue;
    for (final host in hosts) {
      if (identical(host, s)) continue;
      final from = host.startedAt.subtract(_absorbGrace);
      final to = endOf(host).add(_absorbGrace);
      final at = s.clips.single.createdAt;
      if (at.isBefore(from) || at.isAfter(to)) continue;
      (merged[host] ??= []).add(s.clips.single);
      absorbed.add(s);
      break;
    }
  }
  if (absorbed.isEmpty) return sessions;

  return [
    for (final s in sessions)
      if (!absorbed.contains(s))
        if (merged[s] case final extra?)
          ClipSession(
            startedAt: s.startedAt,
            clips: [...s.clips, ...extra]
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
          )
        else
          s,
  ];
}

/// How far outside a session's first/last clip a stray clip still counts as
/// part of it — a hotkey press moments before the first auto-clip, or right
/// after the last one, is still the same match.
const Duration _absorbGrace = Duration(minutes: 2);
