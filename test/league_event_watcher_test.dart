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

/// The shape `_emitMatchInfo` puts in each `allies`/`enemies` entry —
/// matches `MatchPlayer.fromDynamic`'s expected keys exactly.
Map<String, dynamic> _player(String championName, {String? riotId}) =>
    {'championName': championName, 'championKey': null, 'riotId': riotId};

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

  test('a Multikill maps KillStreak to the exact tier, active player only',
      () async {
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed

    Map<String, dynamic> multi(int id, String killer, int streak) => {
          'EventID': id,
          'EventName': 'Multikill',
          'KillerName': killer,
          'KillStreak': streak,
        };
    responses['/liveclientdata/eventdata'] = _events([
      multi(0, 'Me#EUW', 2), // double
      multi(1, 'Me#EUW', 3), // triple
      multi(2, 'Me#EUW', 4), // quadra
      multi(3, 'Me#EUW', 5), // penta
      multi(4, 'Enemy#1', 5), // not us -> ignored
    ]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted.map((e) => e.kind).toList(), [
      GameEventKind.doubleKill,
      GameEventKind.tripleKill,
      GameEventKind.quadraKill,
      GameEventKind.pentaKill,
    ]);
  });

  test('a Multikill with a missing/unknown KillStreak falls back to double',
      () async {
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed

    responses['/liveclientdata/eventdata'] = _events([
      {'EventID': 0, 'EventName': 'Multikill', 'KillerName': 'Me#EUW'},
    ]);
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(emitted.single.kind, GameEventKind.doubleKill);
  });

  test('a 2-team mode (CLASSIC) splits into your team vs enemies', () async {
    responses['/liveclientdata/gamestats'] =
        jsonEncode({'gameMode': 'CLASSIC'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Ahri', 'team': 'ORDER'},
      {'riotId': 'Mate#EUW', 'championName': 'Lux', 'team': 'ORDER'},
      {'riotId': 'Foe1#EUW', 'championName': 'Zed', 'team': 'CHAOS'},
      {'riotId': 'Foe2#EUW', 'championName': 'Yasuo', 'team': 'CHAOS'},
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow(); // post-seed: emits matchInfo
    await Future<void>.delayed(Duration.zero);

    final info = emitted.singleWhere((e) => e.kind == GameEventKind.matchInfo);
    expect(info.meta['champion'], 'Ahri');
    // The RAW code — the friendly name is resolved at render by
    // friendlyLeagueGameMode(), never persisted (see games/league/game_modes.dart).
    expect(info.meta['gameMode'], 'CLASSIC');
    // same team, excludes me; each entry carries the player's name too.
    expect(info.meta['allies'], [_player('Lux', riotId: 'Mate#EUW')]);
    expect(info.meta['enemies'], [
      _player('Zed', riotId: 'Foe1#EUW'),
      _player('Yasuo', riotId: 'Foe2#EUW'),
    ]);
  });

  test('ARAM Mayhem (KIWI) is a real 2-team mode and gets a friendly name',
      () async {
    // Verified against a live match 2026-07-16: ARAM Mayhem reports
    // gameMode "KIWI" (mapName "Map12", the Howling Abyss). Without KIWI in
    // the two-team set it would fall through to the Arena/free-for-all path
    // (flat champion list, no team split) and be labelled "Kiwi".
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'KIWI'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Syndra', 'team': 'ORDER'},
      {'riotId': 'Mate#EUW', 'championName': 'Sona', 'team': 'ORDER'},
      {'riotId': 'Foe#EUW', 'championName': 'Ziggs', 'team': 'CHAOS'},
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow(); // post-seed: emits matchInfo
    await Future<void>.delayed(Duration.zero);

    final info = emitted.singleWhere((e) => e.kind == GameEventKind.matchInfo);
    expect(info.meta['gameMode'], 'KIWI'); // raw; renders as "ARAM Mayhem"
    expect(info.meta['champion'], 'Syndra');
    expect(info.meta['allies'], [_player('Sona', riotId: 'Mate#EUW')]);
    expect(info.meta['enemies'], [_player('Ziggs', riotId: 'Foe#EUW')]);
  });

  test(
      'Arena (CHERRY) has no reliable teams: allies empty, everyone else in '
      'one flat list', () async {
    // Verified live 2026-07-15: Arena\'s ORDER/CHAOS split is arbitrary
    // (12/6 in an 18-player game), NOT the duos — so we never fake a team.
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'CHERRY'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Leona', 'team': 'ORDER'},
      {'riotId': 'A#EUW', 'championName': 'Vex', 'team': 'ORDER'},
      {'riotId': 'B#EUW', 'championName': 'Jax', 'team': 'ORDER'},
      {'riotId': 'C#EUW', 'championName': 'Lux', 'team': 'CHAOS'},
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    final info = emitted.singleWhere((e) => e.kind == GameEventKind.matchInfo);
    expect(info.meta['champion'], 'Leona');
    expect(info.meta['gameMode'], 'CHERRY'); // raw; renders as "Arena"
    expect(info.meta['allies'], isEmpty);
    // all others, flat — still carrying names.
    expect(info.meta['enemies'], [
      _player('Vex', riotId: 'A#EUW'),
      _player('Jax', riotId: 'B#EUW'),
      _player('Lux', riotId: 'C#EUW'),
    ]);
  });

  test('matchInfo is emitted only once per match', () async {
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'ARAM'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Ahri', 'team': 'ORDER'}
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow();
    await watcher.pollNow();
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(
        emitted.where((e) => e.kind == GameEventKind.matchInfo), hasLength(1));
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

  test('allies/enemies also carry each player\'s rawChampionName for art',
      () async {
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'ARAM'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Ahri', 'team': 'ORDER'},
      {
        'riotId': 'Mate#EUW',
        'championName': 'Wukong',
        'rawChampionName': 'game_character_displayname_MonkeyKing',
        'team': 'ORDER',
      },
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    final info = emitted.singleWhere((e) => e.kind == GameEventKind.matchInfo);
    final allies = (info.meta['allies'] as List).cast<Map<String, dynamic>>();
    expect(
        allies.single['championKey'], 'game_character_displayname_MonkeyKing');
  });

  test(
      'a player with no riotId falls back to riotIdGameName#riotIdTagLine, '
      'then summonerName', () async {
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'ARAM'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Ahri', 'team': 'ORDER'},
      {
        'championName': 'Lux',
        'riotIdGameName': 'Mate',
        'riotIdTagLine': 'EUW',
        'team': 'ORDER',
      },
      {
        'championName': 'Zed',
        'summonerName': 'LegacyFoe',
        'team': 'CHAOS',
      },
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    final info = emitted.singleWhere((e) => e.kind == GameEventKind.matchInfo);
    expect(info.meta['allies'], [_player('Lux', riotId: 'Mate#EUW')]);
    expect(info.meta['enemies'], [_player('Zed', riotId: 'LegacyFoe')]);
  });

  test('matchInfo also carries rawChampionName/skinName for art', () async {
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'ARAM'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {
        'riotId': 'Me#EUW',
        'championName': 'Wukong',
        'rawChampionName': 'game_character_displayname_MonkeyKing',
        'skinName': 'Astronaut Wukong',
        'team': 'ORDER',
      }
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow(); // post-seed: emits matchInfo
    await Future<void>.delayed(Duration.zero);

    final info = emitted.singleWhere((e) => e.kind == GameEventKind.matchInfo);
    expect(
        info.meta['rawChampionName'], 'game_character_displayname_MonkeyKing');
    expect(info.meta['skinName'], 'Astronaut Wukong');
  });

  test(
      'a statsUpdate is emitted every poll with assists/creepScore/wardScore/'
      'items from the active player\'s row', () async {
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'ARAM'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {
        'riotId': 'Me#EUW',
        'championName': 'Kayle',
        'team': 'ORDER',
        'scores': {
          'kills': 2,
          'deaths': 1,
          'assists': 5,
          'creepScore': 87,
          'wardScore': 12.4,
        },
        'items': [
          {'itemID': 220013, 'slot': 6, 'displayName': 'Poro-Snax'},
          {'itemID': 3157, 'slot': 0, 'displayName': 'Zhonya\'s Hourglass'},
        ],
      }
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow(); // post-seed: emits matchInfo + statsUpdate
    await Future<void>.delayed(Duration.zero);

    final updates =
        emitted.where((e) => e.kind == GameEventKind.statsUpdate).toList();
    expect(updates, hasLength(1));
    final meta = updates.single.meta;
    expect(meta['assists'], 5);
    expect(meta['creepScore'], 87);
    expect(meta['wardScore'], 12.4);
    expect(meta['items'], [
      {'itemId': 220013, 'slot': 6},
      {'itemId': 3157, 'slot': 0},
    ]);
  });

  test('statsUpdate keeps firing every poll (unlike the one-shot matchInfo)',
      () async {
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'ARAM'});
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Ahri', 'team': 'ORDER'}
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow();
    await watcher.pollNow();
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(
        emitted.where((e) => e.kind == GameEventKind.matchInfo), hasLength(1));
    expect(emitted.where((e) => e.kind == GameEventKind.statsUpdate),
        hasLength(3));
  });

  test('a missing scores/items object never crashes statsUpdate', () async {
    responses['/liveclientdata/gamestats'] = jsonEncode({'gameMode': 'ARAM'});
    // ARAM Mayhem's activePlayer.fullRunes can be `{}` and scores can be
    // entirely absent on some payload shapes — never assume populated.
    responses['/liveclientdata/playerlist'] = jsonEncode([
      {'riotId': 'Me#EUW', 'championName': 'Ahri', 'team': 'ORDER'}
    ]);
    responses['/liveclientdata/eventdata'] = _events([]);
    await watcher.pollNow(); // seed
    await watcher.pollNow();
    await Future<void>.delayed(Duration.zero);

    final update =
        emitted.singleWhere((e) => e.kind == GameEventKind.statsUpdate);
    expect(update.meta['assists'], isNull);
    expect(update.meta['creepScore'], isNull);
    expect(update.meta['wardScore'], isNull);
    expect(update.meta['items'], isEmpty);
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
