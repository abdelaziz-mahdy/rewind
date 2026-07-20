import 'clip.dart';
import 'match_stats.dart';

/// One clip laid on the real match timeline: [start]/[end] are offsets from
/// the match's timeline origin (see [MatchTimelineLayout.origin]).
class TimelineSegment {
  final Clip clip;
  final Duration start;
  final Duration end;

  const TimelineSegment({
    required this.clip,
    required this.start,
    required this.end,
  });

  Duration get length => end - start;
}

/// An event positioned on the match timeline (offset from the origin).
class TimelineEvent {
  final MatchEventStamp stamp;
  final Duration at;

  const TimelineEvent({required this.stamp, required this.at});
}

/// The whole match laid out on its REAL wall-clock timeline: recorded clips
/// as segments, unrecorded spans as the gaps between them, events at their
/// absolute times. Everything the viewer needs, no widget types — pure and
/// unit-tested.
class MatchTimelineLayout {
  /// Wall-clock instant of timeline position zero (the earliest recorded
  /// frame across the match's clips).
  final DateTime origin;

  /// Total span from [origin] to the last recorded frame.
  final Duration span;

  /// Chronological, non-empty segments.
  final List<TimelineSegment> segments;

  /// Events that fall within the span (plus a small tolerance), sorted.
  final List<TimelineEvent> events;

  const MatchTimelineLayout({
    required this.origin,
    required this.span,
    required this.segments,
    required this.events,
  });

  double fractionOf(Duration at) => span.inMilliseconds <= 0
      ? 0
      : (at.inMilliseconds / span.inMilliseconds).clamp(0.0, 1.0);

  /// The segment covering match-position [at], or null when [at] falls in a
  /// gap.
  TimelineSegment? segmentAt(Duration at) {
    for (final s in segments) {
      if (at >= s.start && at < s.end) return s;
    }
    return null;
  }

  /// The first segment starting at/after [at] — where playback lands when a
  /// tap hits a gap. Null past the last segment.
  TimelineSegment? nextSegmentFrom(Duration at) {
    for (final s in segments) {
      if (s.end > at) return s;
    }
    return null;
  }
}

/// Lays [clips] (any order) on the real match timeline. A clip's recording
/// ENDS at its [Clip.createdAt] (the save/event moment flushes the replay
/// buffer backwards), so each spans `createdAt - duration → createdAt`,
/// with per-clip durations supplied by the caller (probed via ffprobe —
/// [durations] keyed by [Clip.path]; clips with no probed duration are
/// skipped rather than guessed). [events] outside the recorded span keep
/// their true position as long as it's within the span (they mark moments
/// that happened during gaps too — that's the point of the view).
MatchTimelineLayout computeMatchTimeline(
  List<Clip> clips,
  Map<String, Duration> durations,
  List<MatchEventStamp> events,
) {
  final spans = <({Clip clip, DateTime start, DateTime end})>[];
  for (final c in clips) {
    final d = durations[c.path];
    if (d == null || d <= Duration.zero) continue;
    spans.add((clip: c, start: c.createdAt.subtract(d), end: c.createdAt));
  }
  spans.sort((a, b) => a.start.compareTo(b.start));
  if (spans.isEmpty) {
    return MatchTimelineLayout(
      origin: clips.isEmpty ? DateTime.now() : clips.first.createdAt,
      span: Duration.zero,
      segments: const [],
      events: const [],
    );
  }

  final origin = spans.first.start;
  var latest = spans.first.end;
  final segments = <TimelineSegment>[];
  for (final s in spans) {
    if (s.end.isAfter(latest)) latest = s.end;
    segments.add(TimelineSegment(
      clip: s.clip,
      start: s.start.difference(origin),
      end: s.end.difference(origin),
    ));
  }
  final span = latest.difference(origin);

  final placed = <TimelineEvent>[
    for (final e in events)
      if (!e.at.isBefore(origin) && !e.at.isAfter(latest))
        TimelineEvent(stamp: e, at: e.at.difference(origin)),
  ]..sort((a, b) => a.at.compareTo(b.at));

  return MatchTimelineLayout(
    origin: origin,
    span: span,
    segments: segments,
    events: placed,
  );
}
