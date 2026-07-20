import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/events/game_event.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_matchstats'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final start = DateTime(2026, 7, 14, 20);

  MatchPlayer mp(String championName, {String? riotId, String? championKey}) =>
      MatchPlayer(
          championName: championName, riotId: riotId, championKey: championKey);

  test('records kills and deaths per (game, session)', () async {
    final store = MatchStatsStore(dir: tmp);
    store.recordKill('league_of_legends', start);
    store.recordKill('league_of_legends', start);
    store.recordDeath('league_of_legends', start);

    final s = store.statsFor('league_of_legends', start)!;
    expect(s.kills, 2);
    expect(s.deaths, 1);
  });

  test('different sessions of the same game are independent', () {
    final store = MatchStatsStore(dir: tmp);
    final later = start.add(const Duration(hours: 1));
    store.recordKill('league_of_legends', start);
    store.recordDeath('league_of_legends', later);

    expect(store.statsFor('league_of_legends', start)!.kills, 1);
    expect(store.statsFor('league_of_legends', start)!.deaths, 0);
    expect(store.statsFor('league_of_legends', later)!.kills, 0);
    expect(store.statsFor('league_of_legends', later)!.deaths, 1);
  });

  test('statsFor returns null for an unrecorded session', () {
    expect(MatchStatsStore(dir: tmp).statsFor('x', start), isNull);
  });

  test('updatedAt tracks the latest mutation and round-trips through disk',
      () async {
    final store = MatchStatsStore(dir: tmp);
    final eventAt = start.add(const Duration(minutes: 5));
    store.recordEvent('league_of_legends', start, GameEventKind.kill, eventAt);
    expect(store.statsFor('league_of_legends', start)!.updatedAt, eventAt);

    await store.save();
    final reloaded = await MatchStatsStore.load(tmp);
    expect(reloaded.statsFor('league_of_legends', start)!.updatedAt, eventAt);
  });

  test('a persisted match without updatedAt (pre-feature) falls back to '
      'startedAt', () {
    final m = MatchStats.fromJson({
      'gameId': 'league_of_legends',
      'startedAt': start.toIso8601String(),
    });
    expect(m.updatedAt, start);
  });

  test('latestFor picks the most recently updated match of that game only',
      () {
    final store = MatchStatsStore(dir: tmp);
    final earlier = start.subtract(const Duration(hours: 2));
    // An old match updated long ago, a new match updated just now, and a
    // different game updated even later — latestFor must pick the middle one.
    store.recordEvent('league_of_legends', earlier, GameEventKind.kill,
        earlier.add(const Duration(minutes: 20)));
    store.recordEvent('league_of_legends', start, GameEventKind.kill,
        start.add(const Duration(minutes: 9)));
    store.recordEvent('other_game', start, GameEventKind.kill,
        start.add(const Duration(minutes: 30)));

    expect(store.latestFor('league_of_legends')!.startedAt, start);
    expect(store.latestFor('missing_game'), isNull);
  });

  test('notifies listeners on each record (live K/D on cards)', () {
    final store = MatchStatsStore(dir: tmp);
    var n = 0;
    store.addListener(() => n++);
    store.recordKill('g', start);
    store.recordDeath('g', start);
    expect(n, 2);
  });

  test('recordMatchInfo stores metadata and never blanks it on empty', () {
    final store = MatchStatsStore(dir: tmp);
    store.recordMatchInfo('league_of_legends', start,
        gameMode: 'Arena',
        champion: 'Ahri',
        allies: [
          mp('Lux', riotId: 'Mate#EUW')
        ],
        enemies: [
          mp('Zed', riotId: 'Foe1#EUW'),
          mp('Yasuo', riotId: 'Foe2#EUW')
        ]);
    var s = store.statsFor('league_of_legends', start)!;
    expect(s.gameMode, 'Arena');
    expect(s.champion, 'Ahri');
    expect(s.allies, [mp('Lux', riotId: 'Mate#EUW')]);
    expect(s.enemies,
        [mp('Zed', riotId: 'Foe1#EUW'), mp('Yasuo', riotId: 'Foe2#EUW')]);

    // A later empty poll must not wipe the earlier capture.
    store.recordMatchInfo('league_of_legends', start,
        champion: '', allies: const []);
    s = store.statsFor('league_of_legends', start)!;
    expect(s.champion, 'Ahri');
    expect(s.allies, [mp('Lux', riotId: 'Mate#EUW')]);
  });

  test('metadata round-trips through matches.json', () async {
    final store = MatchStatsStore(dir: tmp);
    store.recordMatchInfo('league_of_legends', start,
        gameMode: 'ARAM',
        champion: 'Lux',
        allies: [mp('Ahri', riotId: 'Mate#EUW')],
        enemies: [mp('Zed', riotId: 'Foe#EUW')]);
    await store.save();
    final loaded = await MatchStatsStore.load(tmp);
    final s = loaded.statsFor('league_of_legends', start)!;
    expect(s.gameMode, 'ARAM');
    expect(s.champion, 'Lux');
    expect(s.allies, [mp('Ahri', riotId: 'Mate#EUW')]);
    expect(s.enemies, [mp('Zed', riotId: 'Foe#EUW')]);
  });

  test('persists and reloads through matches.json', () async {
    final store = MatchStatsStore(dir: tmp);
    store.recordKill('league_of_legends', start);
    store.recordDeath('league_of_legends', start);
    store.recordDeath('league_of_legends', start);
    await store.save();

    final loaded = await MatchStatsStore.load(tmp);
    final s = loaded.statsFor('league_of_legends', start)!;
    expect(s.kills, 1);
    expect(s.deaths, 2);
  });

  test('a corrupt matches.json is backed up and the store starts empty',
      () async {
    File('${tmp.path}/matches.json').writeAsStringSync('{not json');
    final loaded = await MatchStatsStore.load(tmp);
    expect(loaded.statsFor('x', start), isNull);
    expect(File('${tmp.path}/matches.json.bad').existsSync(), isTrue);
  });

  test('recordMatchInfo also captures championKey/skinName, never blanked', () {
    final store = MatchStatsStore(dir: tmp);
    store.recordMatchInfo('league_of_legends', start,
        rawChampionName: 'game_character_displayname_MonkeyKing',
        skinName: 'Astronaut Wukong');
    var s = store.statsFor('league_of_legends', start)!;
    expect(s.championKey, 'game_character_displayname_MonkeyKing');
    expect(s.skinName, 'Astronaut Wukong');

    // A later empty poll must not wipe the earlier capture.
    store.recordMatchInfo('league_of_legends', start,
        rawChampionName: '', skinName: '');
    s = store.statsFor('league_of_legends', start)!;
    expect(s.championKey, 'game_character_displayname_MonkeyKing');
    expect(s.skinName, 'Astronaut Wukong');
  });

  test('recordStatsUpdate records assists/creepScore/wardScore/items', () {
    final store = MatchStatsStore(dir: tmp);
    store.recordStatsUpdate('league_of_legends', start,
        assists: 3,
        creepScore: 120,
        wardScore: 12.5,
        items: const [
          MatchItemSlot(itemId: 1001, slot: 0),
          MatchItemSlot(itemId: 3006, slot: 1),
        ]);
    final s = store.statsFor('league_of_legends', start)!;
    expect(s.assists, 3);
    expect(s.creepScore, 120);
    expect(s.wardScore, 12.5);
    expect(s.items, [
      const MatchItemSlot(itemId: 1001, slot: 0),
      const MatchItemSlot(itemId: 3006, slot: 1),
    ]);
  });

  test('recordStatsUpdate does not persist/notify when nothing changed', () {
    final store = MatchStatsStore(dir: tmp);
    store.recordStatsUpdate('g', start, assists: 1, creepScore: 10);
    var n = 0;
    store.addListener(() => n++);
    // Identical values: must be a no-op (matches.json is written often;
    // an idle match must not rewrite it every poll).
    store.recordStatsUpdate('g', start, assists: 1, creepScore: 10);
    expect(n, 0);

    store.recordStatsUpdate('g', start, assists: 2);
    expect(n, 1);
  });

  test('MatchStats round-trips the full stat line through matches.json',
      () async {
    final store = MatchStatsStore(dir: tmp);
    store.recordMatchInfo('league_of_legends', start,
        gameMode: 'ARAM',
        champion: 'Lux',
        rawChampionName: 'game_character_displayname_Lux',
        skinName: 'Elderwood Lux');
    store.recordStatsUpdate('league_of_legends', start,
        assists: 7,
        creepScore: 40,
        wardScore: 3.0,
        items: const [MatchItemSlot(itemId: 3157, slot: 0)]);
    await store.save();

    final loaded = await MatchStatsStore.load(tmp);
    final s = loaded.statsFor('league_of_legends', start)!;
    expect(s.championKey, 'game_character_displayname_Lux');
    expect(s.skinName, 'Elderwood Lux');
    expect(s.assists, 7);
    expect(s.creepScore, 40);
    expect(s.wardScore, 3.0);
    expect(s.items, [const MatchItemSlot(itemId: 3157, slot: 0)]);
  });

  test(
      'loading a legacy matches.json (no new fields) never crashes and '
      'defaults sanely', () async {
    // A real pre-feature matches.json shape (kills/deaths/gameMode/champion/
    // allies/enemies only) — must load without throwing.
    File('${tmp.path}/matches.json').writeAsStringSync(jsonEncode({
      'matches': [
        {
          'gameId': 'league_of_legends',
          'startedAt': start.toIso8601String(),
          'kills': 4,
          'deaths': 2,
          'gameMode': 'ARAM',
          'champion': 'Ahri',
          'allies': ['Lux'],
          'enemies': ['Zed'],
        }
      ]
    }));

    final loaded = await MatchStatsStore.load(tmp);
    final s = loaded.statsFor('league_of_legends', start)!;
    expect(s.kills, 4);
    expect(s.deaths, 2);
    expect(s.champion, 'Ahri');
    expect(s.championKey, isNull);
    expect(s.skinName, isNull);
    expect(s.assists, 0);
    expect(s.creepScore, 0);
    expect(s.wardScore, 0.0);
    expect(s.items, isEmpty);
    // The pre-username shape stored allies/enemies as bare champion-name
    // strings: must still parse into MatchPlayers, with no name attached.
    expect(s.allies, [const MatchPlayer(championName: 'Lux')]);
    expect(s.enemies, [const MatchPlayer(championName: 'Zed')]);
    expect(s.allies.single.riotId, isNull);
  });

  group('MatchEventStamp / MatchStats.events', () {
    test('recordEvent appends a stamp for every kind, not just kill/death', () {
      final store = MatchStatsStore(dir: tmp);
      final t1 = start.add(const Duration(seconds: 1));
      final t2 = start.add(const Duration(seconds: 2));
      store.recordEvent('league_of_legends', start, GameEventKind.kill, t1);
      store.recordEvent(
          'league_of_legends', start, GameEventKind.dragonKill, t2);

      final s = store.statsFor('league_of_legends', start)!;
      expect(s.events, [
        MatchEventStamp(kind: GameEventKind.kill, at: t1),
        MatchEventStamp(kind: GameEventKind.dragonKill, at: t2),
      ]);
    });

    test(
        'recordEvent is the single path: recordKill/recordDeath still bump '
        'counts exactly once each (no double-counting)', () {
      final store = MatchStatsStore(dir: tmp);
      store.recordKill('league_of_legends', start);
      store.recordKill('league_of_legends', start);
      store.recordDeath('league_of_legends', start);

      final s = store.statsFor('league_of_legends', start)!;
      expect(s.kills, 2);
      expect(s.deaths, 1);
      // Every recordKill/recordDeath call also lands exactly one event
      // stamp — three calls, three stamps, none dropped or duplicated.
      expect(s.events, hasLength(3));
      expect(s.events.where((e) => e.kind == GameEventKind.kill), hasLength(2));
      expect(
          s.events.where((e) => e.kind == GameEventKind.death), hasLength(1));
    });

    test('a non-combat kind (e.g. victory) is stamped but never counted', () {
      final store = MatchStatsStore(dir: tmp);
      store.recordEvent(
          'league_of_legends', start, GameEventKind.victory, start);

      final s = store.statsFor('league_of_legends', start)!;
      expect(s.kills, 0);
      expect(s.deaths, 0);
      expect(
          s.events, [MatchEventStamp(kind: GameEventKind.victory, at: start)]);
    });

    test('events round-trip through matches.json', () async {
      final store = MatchStatsStore(dir: tmp);
      final at = start.add(const Duration(seconds: 30));
      store.recordEvent(
          'league_of_legends', start, GameEventKind.pentaKill, at);
      await store.save();

      final loaded = await MatchStatsStore.load(tmp);
      final s = loaded.statsFor('league_of_legends', start)!;
      expect(
          s.events, [MatchEventStamp(kind: GameEventKind.pentaKill, at: at)]);
    });

    test(
        'an absent `events` key (pre-feature matches.json) loads as empty, '
        'not a crash', () async {
      File('${tmp.path}/matches.json').writeAsStringSync(jsonEncode({
        'matches': [
          {
            'gameId': 'league_of_legends',
            'startedAt': start.toIso8601String(),
            'kills': 1,
            'deaths': 0,
          }
        ]
      }));

      final loaded = await MatchStatsStore.load(tmp);
      final s = loaded.statsFor('league_of_legends', start)!;
      expect(s.events, isEmpty);
    });

    test('the event log is capped, dropping the oldest beyond the cap', () {
      final store = MatchStatsStore(dir: tmp);
      for (var i = 0; i < MatchStatsStore.maxEvents + 10; i++) {
        store.recordEvent('league_of_legends', start, GameEventKind.other,
            start.add(Duration(seconds: i)));
      }

      final s = store.statsFor('league_of_legends', start)!;
      expect(s.events, hasLength(MatchStatsStore.maxEvents));
      // The oldest 10 were dropped: the first surviving stamp is #10.
      expect(s.events.first.at, start.add(const Duration(seconds: 10)));
      expect(
        s.events.last.at,
        start.add(const Duration(seconds: 509)),
      );
    });
  });

  group('MatchPlayer.fromDynamic', () {
    test('parses the current object shape', () {
      final p = MatchPlayer.fromDynamic(const {
        'championName': 'Ahri',
        'championKey': 'game_character_displayname_Ahri',
        'riotId': 'Me#EUW',
      });
      expect(p.championName, 'Ahri');
      expect(p.championKey, 'game_character_displayname_Ahri');
      expect(p.riotId, 'Me#EUW');
    });

    test('parses a legacy bare champion-name string with no name', () {
      final p = MatchPlayer.fromDynamic('Ahri');
      expect(p.championName, 'Ahri');
      expect(p.championKey, isNull);
      expect(p.riotId, isNull);
    });

    test('round-trips through toJson', () {
      const p = MatchPlayer(
          championName: 'Ahri', championKey: 'raw', riotId: 'Me#EUW');
      final round = MatchPlayer.fromDynamic(p.toJson());
      expect(round, p);
    });
  });
  test('recordOutcome sets and persists the win/loss, once', () async {
    final store = MatchStatsStore(dir: tmp);
    store.recordOutcome('league_of_legends', start, MatchResult.win);
    expect(store.statsFor('league_of_legends', start)!.result, MatchResult.win);

    // A stray later report must not flip a decided result.
    store.recordOutcome('league_of_legends', start, MatchResult.loss);
    expect(store.statsFor('league_of_legends', start)!.result, MatchResult.win);

    await store.save();
    final reloaded = await MatchStatsStore.load(tmp);
    expect(reloaded.statsFor('league_of_legends', start)!.result,
        MatchResult.win);
  });

  test('a persisted match without result (pre-feature) is null', () {
    final m = MatchStats.fromJson({
      'gameId': 'league_of_legends',
      'startedAt': start.toIso8601String(),
    });
    expect(m.result, isNull);
  });

  test('MatchResult.tryParse handles win/loss/unknown', () {
    expect(MatchResult.tryParse('win'), MatchResult.win);
    expect(MatchResult.tryParse('loss'), MatchResult.loss);
    expect(MatchResult.tryParse('WIN'), MatchResult.win);
    expect(MatchResult.tryParse(null), isNull);
    expect(MatchResult.tryParse('draw'), isNull);
  });

}
