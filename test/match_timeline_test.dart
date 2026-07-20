import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/match_export.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/clip/match_timeline.dart';
import 'package:rewind/src/events/game_event.dart';

Clip _clip(String path, DateTime createdAt) => Clip(
      path: path,
      gameId: 'league_of_legends',
      event: GameEventKind.kill,
      createdAt: createdAt,
      sizeBytes: 1,
    );

void main() {
  final t0 = DateTime(2026, 7, 20, 21, 0, 0);

  group('computeMatchTimeline', () {
    test('lays clips on the real timeline with gaps between them', () {
      // Clip A recorded 21:00:00→21:00:30 (created at :30, 30 s long),
      // clip B 21:05:00→21:05:20. Origin = A's start; the 4:30 between
      // them is a gap, not compressed away.
      final a = _clip('/a.mp4', t0.add(const Duration(seconds: 30)));
      final b = _clip('/b.mp4', t0.add(const Duration(minutes: 5, seconds: 20)));
      final layout = computeMatchTimeline(
        [b, a], // any order in — chronological out
        {
          '/a.mp4': const Duration(seconds: 30),
          '/b.mp4': const Duration(seconds: 20),
        },
        const [],
      );

      expect(layout.origin, t0);
      expect(layout.span, const Duration(minutes: 5, seconds: 20));
      expect(layout.segments, hasLength(2));
      expect(layout.segments.first.clip.path, '/a.mp4');
      expect(layout.segments.first.start, Duration.zero);
      expect(layout.segments.first.end, const Duration(seconds: 30));
      expect(layout.segments.last.start, const Duration(minutes: 5));
    });

    test('clips without a probed duration are skipped, not guessed', () {
      final a = _clip('/a.mp4', t0.add(const Duration(seconds: 30)));
      final broken = _clip('/gone.mp4', t0.add(const Duration(minutes: 2)));
      final layout = computeMatchTimeline(
        [a, broken],
        {'/a.mp4': const Duration(seconds: 30)},
        const [],
      );
      expect(layout.segments, hasLength(1));
      expect(layout.segments.single.clip.path, '/a.mp4');
    });

    test('events keep their true position — including inside gaps', () {
      final a = _clip('/a.mp4', t0.add(const Duration(seconds: 30)));
      final b = _clip('/b.mp4', t0.add(const Duration(minutes: 5, seconds: 20)));
      final layout = computeMatchTimeline(
        [a, b],
        {
          '/a.mp4': const Duration(seconds: 30),
          '/b.mp4': const Duration(seconds: 20),
        },
        [
          MatchEventStamp(
              kind: GameEventKind.kill,
              at: t0.add(const Duration(minutes: 2))), // mid-gap
          MatchEventStamp(
              kind: GameEventKind.kill,
              at: t0.subtract(const Duration(minutes: 1))), // pre-match
        ],
      );
      expect(layout.events, hasLength(1));
      expect(layout.events.single.at, const Duration(minutes: 2));
    });

    test('segmentAt and nextSegmentFrom cover gap seeking', () {
      final a = _clip('/a.mp4', t0.add(const Duration(seconds: 30)));
      final b = _clip('/b.mp4', t0.add(const Duration(minutes: 5, seconds: 20)));
      final layout = computeMatchTimeline(
        [a, b],
        {
          '/a.mp4': const Duration(seconds: 30),
          '/b.mp4': const Duration(seconds: 20),
        },
        const [],
      );
      expect(layout.segmentAt(const Duration(seconds: 10))!.clip.path, '/a.mp4');
      expect(layout.segmentAt(const Duration(minutes: 2)), isNull);
      expect(layout.nextSegmentFrom(const Duration(minutes: 2))!.clip.path,
          '/b.mp4');
      expect(layout.nextSegmentFrom(const Duration(minutes: 6)), isNull);
    });
  });

  group('match export helpers', () {
    test('concatListBody quotes paths, ffconcat header first', () {
      expect(
        concatListBody(['/clips/a.mp4', "/clips/it's here.mp4"]),
        "ffconcat version 1.0\n"
        "file '/clips/a.mp4'\n"
        "file '/clips/it'\\''s here.mp4'\n",
      );
    });

    test('concatArguments stream-copies from the list file', () {
      expect(
        concatArguments('/tmp/list.txt', '/clips/out.mp4'),
        ['-f', 'concat', '-safe', '0', '-i', '/tmp/list.txt', '-c', 'copy',
         '-y', '/clips/out.mp4'],
      );
    });

    test('matchExportPath suffixes and bumps collisions', () {
      final first = _clip('/clips/rewind-1.mp4', t0);
      expect(matchExportPath(first, const []),
          '/clips/rewind-1-full-match.mp4');
      expect(
        matchExportPath(first, const ['/clips/rewind-1-full-match.mp4']),
        '/clips/rewind-1-full-match-2.mp4',
      );
    });
  });
}
