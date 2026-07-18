import 'package:flutter/foundation.dart';

import '../events/game_event.dart';
import 'clip.dart';
import 'match_stats.dart';

/// One tick on the player's timeline (`TimelineMarkers`): an event kind and
/// where it falls inside the clip's OWN footage, not the match's absolute
/// clock. See [computeClipMarkers].
@immutable
class ClipMarker {
  final GameEventKind kind;
  final Duration offset;

  const ClipMarker({required this.kind, required this.offset});

  @override
  bool operator ==(Object other) =>
      other is ClipMarker && other.kind == kind && other.offset == offset;

  @override
  int get hashCode => Object.hash(kind, offset);

  @override
  String toString() => 'ClipMarker(${kind.name}, $offset)';
}

/// Tolerance for clock skew between an event's timestamp and the clip's own
/// save-time clock read (both `DateTime.now()` calls, just at slightly
/// different moments — matches the ~500 ms cadence the Live Client watcher
/// already polls at, see [GameEventKind.statsUpdate]'s doc). An offset that
/// lands only marginally outside `[0, duration]` because of that skew is
/// clamped to the nearest bound instead of being dropped — it plainly
/// belongs in this clip. Anything further outside is a genuinely different
/// moment in the match and is dropped instead, so a single clip doesn't end
/// up smeared with every event of a long match.
const Duration clipMarkerClockSkewTolerance = Duration(milliseconds: 500);

/// Computes the timeline markers for one clip: given the [clip], its actual
/// playback [duration] (only known once the player has loaded the file —
/// see `PlayerScreen`), and the match's recorded [events], returns one
/// [ClipMarker] per event whose timestamp falls inside the clip's footage
/// window, positioned by [ClipMarker.offset] from the start of that footage.
///
/// The footage window starts at `clip.createdAt - duration` (the clip's
/// `createdAt` is always the event time that triggered the save — the END
/// of the footage window, see `ClipCoordinator._indexClip`) and ends at
/// `clip.createdAt`. Events outside that window (i.e. from a different fight
/// in the same match) are dropped; events within
/// [clipMarkerClockSkewTolerance] of a boundary are clamped onto it rather
/// than dropped or left to throw on a negative/oversized [Duration].
List<ClipMarker> computeClipMarkers({
  required Clip clip,
  required Duration duration,
  required List<MatchEventStamp> events,
}) {
  if (duration <= Duration.zero || events.isEmpty) return const [];
  final clipStart = clip.createdAt.subtract(duration);

  final markers = <ClipMarker>[];
  for (final event in events) {
    var offset = event.at.difference(clipStart);
    if (offset.isNegative) {
      if (-offset > clipMarkerClockSkewTolerance) continue; // a different fight
      offset = Duration.zero;
    } else if (offset > duration) {
      if (offset - duration > clipMarkerClockSkewTolerance) continue;
      offset = duration;
    }
    markers.add(ClipMarker(kind: event.kind, offset: offset));
  }
  return markers;
}
