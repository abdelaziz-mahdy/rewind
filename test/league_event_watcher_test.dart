import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/league_event_watcher.dart';

Map<String, dynamic> _kill(int id, String killer,
        [String victim = 'someone']) =>
    {
      'EventID': id,
      'EventName': 'ChampionKill',
      'KillerName': killer,
      'VictimName': victim,
    };

String _events(List<Map<String, dynamic>> events) =>
    jsonEncode({'Events': events});

void main() {
  late Map<String, String?> responses;
  late LeagueEventWatcher watcher;
  late List<GameEvent> emitted;

  setUp(() {
    responses = {
      '/liveclientdata/activeplayername': jsonEncode('Me#EUW'),
      '/liveclientdata/gamestats': '{"gameMode":"CLASSIC"}',
    };
    watcher = LeagueEventWatcher(fetch: (path) async => responses[path]);
    emitted = [];
    watcher.events().listen(emitted.add);
  });

  tearDown(() => watcher.stop());

  test('isGameRunning reflects whether gamestats answers', () async {
    expect(await watcher.isGameRunning(), isTrue);
    responses['/liveclientdata/gamestats'] = null;
    expect(await watcher.isGameRunning(), isFalse);
  });

  test('the first poll seeds past match history without emitting anything',
      () async {
    // Connecting mid-match: the log already holds everyone's kills. The
    // 2026-07-14 incident replayed ALL of them as clips at once.
    responses['/liveclientdata/eventdata'] = _events([
      _kill(0, 'Me#EUW'),
      _kill(1, 'Enemy#1'),
      _kill(2, 'Me#EUW'),
    ]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isEmpty);
  });

  test('after seeding, only the ACTIVE PLAYER\'s new kills emit', () async {
    responses['/liveclientdata/eventdata'] = _events([_kill(0, 'Enemy#1')]);
    await watcher.pollNow(); // seed

    // eventdata is match-global (16 players in Arena) — everyone's kills
    // arrive; only ours may clip.
    responses['/liveclientdata/eventdata'] = _events([
      _kill(0, 'Enemy#1'),
      _kill(1, 'Teammate#2'),
      _kill(2, 'Me#EUW'),
      _kill(3, 'Enemy#1'),
    ]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted, hasLength(1));
    expect(emitted.single.kind, GameEventKind.kill);
  });

  test(
      'events naming the player by tagless GAME NAME still match the riot-id '
      'activeplayername', () async {
    // Live-verified 2026-07-14: activeplayername returns "zezo12321#EUW"
    // while KillerName is the bare game name — the exact-match filter
    // rejected the player's own kills.
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed

    responses['/liveclientdata/eventdata'] = _events([
      _kill(0, 'Me'), // tagless
      _kill(1, 'Meow'), // must NOT match by prefix
    ]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted, hasLength(1));
  });

  test('a ChampionKill where the player is the VICTIM emits a death', () async {
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed

    responses['/liveclientdata/eventdata'] = _events([
      _kill(0, 'Enemy#1', 'Me#EUW'), // player killed -> death
      _kill(1, 'Me#EUW', 'Enemy#1'), // player killed someone -> kill
    ]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted.map((e) => e.kind),
        containsAll([GameEventKind.death, GameEventKind.kill]));
    // Someone else killing someone else is neither.
    expect(emitted, hasLength(2));
  });

  test('an already-seen EventID never re-emits (poll after poll)', () async {
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed on empty history

    responses['/liveclientdata/eventdata'] = _events([_kill(0, 'Me#EUW')]);
    await watcher.pollNow();
    await watcher.pollNow();
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted, hasLength(1));
  });

  test('Ace attributes by Acer', () async {
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow();

    responses['/liveclientdata/eventdata'] = _events([
      {
        'EventID': 0,
        'EventName': 'Ace',
        'Acer': 'Me#EUW',
        'AcingTeam': 'ORDER'
      },
      {
        'EventID': 1,
        'EventName': 'Ace',
        'Acer': 'Enemy#1',
        'AcingTeam': 'CHAOS'
      },
    ]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted, hasLength(1));
    expect(emitted.single.kind, GameEventKind.ace);
  });

  test(
      'no resolvable active player name means NO player-scoped emissions '
      '(fail closed, never spam)', () async {
    responses['/liveclientdata/activeplayername'] = null;
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow();

    responses['/liveclientdata/eventdata'] = _events([_kill(0, 'Me#EUW')]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isEmpty);
  });

  test(
      'stop() resets the session: the next poll re-seeds instead of '
      'replaying', () async {
    responses['/liveclientdata/eventdata'] = _events([_kill(0, 'Me#EUW')]);
    await watcher.pollNow(); // seed
    await watcher.stop();

    // Same history is still in the log on reconnect — must re-seed, not
    // emit.
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isEmpty);
  });
}
