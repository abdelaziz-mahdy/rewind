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
}
