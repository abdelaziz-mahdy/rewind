import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/clip_sessions.dart';

Clip _clip(String name, DateTime at, {DateTime? sessionAt}) => Clip(
      path: '/tmp/$name.mp4',
      gameId: 'league_of_legends',
      event: GameEventKind.kill,
      createdAt: at,
      sizeBytes: 1,
      sessionAt: sessionAt,
    );

void main() {
  group('groupClipsIntoSessions', () {
    test('clips sharing a sessionAt stamp form exactly one session', () {
      final match1 = DateTime(2026, 7, 14, 20);
      final match2 = DateTime(2026, 7, 14, 21, 30);
      final sessions = groupClipsIntoSessions([
        _clip('a', DateTime(2026, 7, 14, 20, 10), sessionAt: match1),
        _clip('b', DateTime(2026, 7, 14, 20, 25), sessionAt: match1),
        _clip('c', DateTime(2026, 7, 14, 21, 40), sessionAt: match2),
      ]);

      expect(sessions, hasLength(2));
      // Newest session first; clips newest first within it.
      expect(sessions[0].startedAt, match2);
      expect(sessions[0].clips.map((c) => c.path), ['/tmp/c.mp4']);
      expect(sessions[1].startedAt, match1);
      expect(
          sessions[1].clips.map((c) => c.path), ['/tmp/b.mp4', '/tmp/a.mp4']);
    });

    test('unstamped clips gap-cluster: >30 min apart starts a new session', () {
      final sessions = groupClipsIntoSessions([
        _clip('old1', DateTime(2026, 7, 14, 18, 0)),
        _clip('old2', DateTime(2026, 7, 14, 18, 20)), // 20 min later: same
        _clip('new1', DateTime(2026, 7, 14, 20, 0)), // 100 min later: new
      ]);

      expect(sessions, hasLength(2));
      expect(sessions[0].clips.map((c) => c.path), ['/tmp/new1.mp4']);
      expect(sessions[1].clips.map((c) => c.path),
          ['/tmp/old2.mp4', '/tmp/old1.mp4']);
      // A gap-clustered session is anchored at its OLDEST clip.
      expect(sessions[1].startedAt, DateTime(2026, 7, 14, 18, 0));
    });

    test('stamped and unstamped clips coexist, globally newest-first', () {
      final stamp = DateTime(2026, 7, 14, 20);
      final sessions = groupClipsIntoSessions([
        _clip('legacy', DateTime(2026, 7, 14, 12)),
        _clip('stamped', DateTime(2026, 7, 14, 20, 5), sessionAt: stamp),
      ]);

      expect(sessions, hasLength(2));
      expect(sessions[0].startedAt, stamp);
      expect(sessions[1].clips.single.path, '/tmp/legacy.mp4');
    });

    test('empty input yields no sessions', () {
      expect(groupClipsIntoSessions(const []), isEmpty);
    });
  });

  test('Clip.sessionAt round-trips through JSON (and null stays null)', () {
    final stamped = _clip('a', DateTime(2026, 7, 14, 20, 10),
        sessionAt: DateTime(2026, 7, 14, 20));
    expect(
        Clip.fromJson(stamped.toJson()).sessionAt, DateTime(2026, 7, 14, 20));
    final bare = _clip('b', DateTime(2026, 7, 14, 20, 10));
    expect(Clip.fromJson(bare.toJson()).sessionAt, isNull);
  });

  group('a stray clip inside a match joins that match', () {
    test(
        'a manual clip stamped with its own session lands in the match it '
        'was taken during', () {
      // The exact shape of a real library (2026-07-24): a League match with
      // its auto-clips, and a hotkey clip saved mid-match that got stamped
      // under the CLIENT's activation instead of the match's, stranding it
      // as a one-clip session beside the match it came from.
      final matchStart = DateTime(2026, 7, 24, 19, 58);
      final match = [
        for (var i = 0; i < 4; i++)
          _clip('k$i', matchStart.add(Duration(minutes: 2 + i * 5)),
              sessionAt: matchStart),
      ];
      final strayStamp = DateTime(2026, 7, 24, 20, 4, 34);
      final stray = _clip('manual', strayStamp, sessionAt: strayStamp);

      final sessions = groupClipsIntoSessions([...match, stray]);

      expect(sessions, hasLength(1));
      expect(sessions.single.startedAt, matchStart);
      expect(sessions.single.clips, hasLength(5));
      expect(sessions.single.clips.map((c) => c.path), contains(stray.path));
    });

    test('a clip OUTSIDE every match keeps its own session', () {
      final matchStart = DateTime(2026, 7, 24, 19, 58);
      final match = [
        for (var i = 0; i < 3; i++)
          _clip('k$i', matchStart.add(Duration(minutes: 2 + i * 5)),
              sessionAt: matchStart),
      ];
      // Well after the last clip of the match, and past the grace window.
      final later = DateTime(2026, 7, 24, 21, 30);
      final sessions = groupClipsIntoSessions(
          [...match, _clip('m', later, sessionAt: later)]);

      expect(sessions, hasLength(2));
    });

    test('two real matches never merge into one', () {
      // Containment, not proximity: neither match lies inside the other, so
      // back-to-back matches must stay two cards no matter how close they
      // are. (Merging them is the failure this replaced — see the
      // 2026-07-24 "two games are getting mixed up" report.)
      final a = DateTime(2026, 7, 24, 19, 0);
      final b = DateTime(2026, 7, 24, 19, 40);
      final clips = [
        for (var i = 0; i < 3; i++)
          _clip('a$i', a.add(Duration(minutes: 2 + i * 5)), sessionAt: a),
        for (var i = 0; i < 3; i++)
          _clip('b$i', b.add(Duration(minutes: 2 + i * 5)), sessionAt: b),
      ];
      final sessions = groupClipsIntoSessions(clips);

      expect(sessions, hasLength(2));
      expect(sessions.map((s) => s.startedAt), containsAll([a, b]));
    });

    test('a lone clip never swallows a match', () {
      // Only a session with more than one clip can absorb, so a single
      // manual can't become the host and rename the group.
      final matchStart = DateTime(2026, 7, 24, 19, 58);
      final solo = _clip('solo', matchStart.add(const Duration(minutes: 5)),
          sessionAt: matchStart.add(const Duration(minutes: 5)));
      final other = _clip('other', matchStart.add(const Duration(minutes: 6)),
          sessionAt: matchStart.add(const Duration(minutes: 6)));

      final sessions = groupClipsIntoSessions([solo, other]);
      expect(sessions, hasLength(2));
    });
  });
}
