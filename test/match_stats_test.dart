import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/match_stats.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_matchstats'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final start = DateTime(2026, 7, 14, 20);

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

  test('notifies listeners on each record (live K/D on cards)', () {
    final store = MatchStatsStore(dir: tmp);
    var n = 0;
    store.addListener(() => n++);
    store.recordKill('g', start);
    store.recordDeath('g', start);
    expect(n, 2);
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
}
