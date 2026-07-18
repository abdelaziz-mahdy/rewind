import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_markers.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/events/game_event.dart';

void main() {
  // A 30 s clip saved at this instant: its footage window is
  // [createdAt - 30s, createdAt] (see ClipCoordinator._indexClip's windowEnd/
  // start contract, which computeClipMarkers's doc mirrors).
  final createdAt = DateTime(2026, 7, 16, 20, 30);
  const duration = Duration(seconds: 30);
  final clipStart = createdAt.subtract(duration);

  Clip clip({DateTime? at}) => Clip(
        path: '/tmp/clip.mp4',
        gameId: 'league_of_legends',
        event: GameEventKind.kill,
        createdAt: at ?? createdAt,
        sizeBytes: 1,
      );

  MatchEventStamp stamp(GameEventKind kind, Duration fromClipStart) =>
      MatchEventStamp(kind: kind, at: clipStart.add(fromClipStart));

  test('an event mid-clip becomes a marker at its offset from clip start', () {
    final markers = computeClipMarkers(
      clip: clip(),
      duration: duration,
      events: [stamp(GameEventKind.kill, const Duration(seconds: 12))],
    );

    expect(markers, [
      const ClipMarker(kind: GameEventKind.kill, offset: Duration(seconds: 12))
    ]);
  });

  test('multiple events each get their own marker, order preserved', () {
    final markers = computeClipMarkers(
      clip: clip(),
      duration: duration,
      events: [
        stamp(GameEventKind.kill, const Duration(seconds: 5)),
        stamp(GameEventKind.death, const Duration(seconds: 20)),
      ],
    );

    expect(markers, [
      const ClipMarker(kind: GameEventKind.kill, offset: Duration(seconds: 5)),
      const ClipMarker(
          kind: GameEventKind.death, offset: Duration(seconds: 20)),
    ]);
  });

  test('empty events returns an empty list', () {
    expect(computeClipMarkers(clip: clip(), duration: duration, events: []),
        isEmpty);
  });

  test(
      'a zero (unknown) duration returns an empty list rather than '
      'dividing by zero', () {
    final markers = computeClipMarkers(
      clip: clip(),
      duration: Duration.zero,
      events: [stamp(GameEventKind.kill, const Duration(seconds: 5))],
    );
    expect(markers, isEmpty);
  });

  group('exactly-at-bounds events', () {
    test('an event exactly at clip start (offset 0) is kept', () {
      final markers = computeClipMarkers(
        clip: clip(),
        duration: duration,
        events: [stamp(GameEventKind.kill, Duration.zero)],
      );
      expect(markers,
          [const ClipMarker(kind: GameEventKind.kill, offset: Duration.zero)]);
    });

    test('an event exactly at clip end (offset == duration) is kept', () {
      final markers = computeClipMarkers(
        clip: clip(),
        duration: duration,
        events: [stamp(GameEventKind.kill, duration)],
      );
      expect(markers,
          [const ClipMarker(kind: GameEventKind.kill, offset: duration)]);
    });
  });

  group('clock skew: clamp, not crash', () {
    test(
        'an event a few ms before clip start is clamped to zero, not '
        'dropped or thrown', () {
      final skewed =
          stamp(GameEventKind.kill, const Duration(milliseconds: -200));
      final markers = computeClipMarkers(
        clip: clip(),
        duration: duration,
        events: [skewed],
      );
      expect(markers,
          [const ClipMarker(kind: GameEventKind.kill, offset: Duration.zero)]);
    });

    test('an event a few ms past clip end is clamped to duration', () {
      final skewed = stamp(
          GameEventKind.kill, duration + const Duration(milliseconds: 200));
      final markers = computeClipMarkers(
        clip: clip(),
        duration: duration,
        events: [skewed],
      );
      expect(markers,
          [const ClipMarker(kind: GameEventKind.kill, offset: duration)]);
    });

    test(
        'an event far outside the window (a different fight) is dropped, '
        'not clamped onto the boundary', () {
      final markers = computeClipMarkers(
        clip: clip(),
        duration: duration,
        events: [
          stamp(GameEventKind.kill, const Duration(seconds: -90)),
          stamp(GameEventKind.kill, const Duration(seconds: 90)),
        ],
      );
      expect(markers, isEmpty);
    });
  });
}
