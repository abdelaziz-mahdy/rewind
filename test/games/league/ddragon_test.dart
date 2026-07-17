import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/games/league/ddragon.dart';

void main() {
  late Directory tmp;
  late List<Uri> fetched;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_ddragon');
    fetched = [];
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  DDragon build({
    String? versions = '["16.14.1","16.13.1"]',
    List<int>? image = const [1, 2, 3],
  }) =>
      DDragon(
        cacheDir: tmp,
        fetchText: (url) async {
          fetched.add(url);
          return versions;
        },
        fetchBytes: (url) async {
          fetched.add(url);
          return image;
        },
      );

  group('championKey (Data Dragon keys art by INTERNAL id, not display name)',
      () {
    test('takes the id out of rawChampionName', () {
      // Verified against a live match 2026-07-16.
      expect(
          DDragon.championKey('game_character_displayname_Syndra'), 'Syndra');
    });

    test(
        'Wukong resolves to MonkeyKing — the whole reason we parse the raw '
        'name instead of using championName', () {
      expect(
        DDragon.championKey('game_character_displayname_MonkeyKing',
            championName: 'Wukong'),
        'MonkeyKing',
      );
    });

    test('falls back to a punctuation-stripped display name', () {
      expect(DDragon.championKey(null, championName: 'Nunu & Willump'),
          'NunuWillump');
      expect(DDragon.championKey('', championName: "Kai'Sa"), 'KaiSa');
    });

    test('null when nothing is resolvable', () {
      expect(DDragon.championKey(null), isNull);
      expect(DDragon.championKey('', championName: ''), isNull);
    });
  });

  test('version resolves to the newest entry and is fetched only once',
      () async {
    final d = build();
    expect(await d.version(), '16.14.1');
    expect(await d.version(), '16.14.1');
    expect(
        fetched.where((u) => u.path.contains('versions.json')), hasLength(1));
  });

  test('championSquare downloads once, then serves from disk', () async {
    final d = build();
    final f = await d.championSquare('game_character_displayname_Syndra');
    expect(f, isNotNull);
    expect(f!.existsSync(), isTrue);
    expect(f.path, contains(pathFrag('16.14.1', 'champion', 'Syndra.png')));

    final imageFetches =
        fetched.where((u) => u.path.endsWith('champion/Syndra.png')).length;

    // Second call must not hit the network — a match in progress can't pay
    // for downloads.
    final again = await d.championSquare('game_character_displayname_Syndra');
    expect(again!.path, f.path);
    expect(fetched.where((u) => u.path.endsWith('champion/Syndra.png')).length,
        imageFetches);
  });

  test('itemIcon caches by itemID', () async {
    final d = build();
    final f = await d.itemIcon(3340);
    expect(f, isNotNull);
    expect(f!.path, contains(pathFrag('16.14.1', 'item', '3340.png')));
    expect(f.readAsBytesSync(), [1, 2, 3]);
  });

  test('a failed image fetch returns null rather than caching an empty file',
      () async {
    final d = build(image: null);
    expect(await d.championSquare('game_character_displayname_Syndra'), isNull);
    expect(
      Directory(tmp.path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.png')),
      isEmpty,
    );
  });

  test('with no network, version falls back to the last one seen on disk',
      () async {
    // Warm the marker.
    expect(await build().version(), '16.14.1');
    // Now Riot is unreachable: already-cached art must still resolve.
    final offline = build(versions: null);
    expect(await offline.version(), '16.14.1');
  });

  test('no version and no marker means null, not a crash', () async {
    expect(await build(versions: null).version(), isNull);
    expect(await build(versions: 'not json').version(), isNull);
  });

  test('versions.json is requested from Riot\'s official CDN over https',
      () async {
    await build().version();
    final u = fetched.first;
    expect(u.scheme, 'https');
    expect(u.host, 'ddragon.leagueoflegends.com');
    expect(u.path, '/api/versions.json');
  });
}

/// Platform-correct path fragment for `contains` assertions.
String pathFrag(String a, String b, String c) =>
    [a, b, c].join(Platform.pathSeparator);
