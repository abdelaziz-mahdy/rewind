import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/games/steam_icon_resolver.dart';

/// Builds a fake Steam tree under [root] for one game and returns the
/// `steamapps` dir. Mirrors the real on-disk layout verified 2026-07-21:
///   <root>/steamapps/appmanifest_<appid>.acf
///   <root>/steamapps/common/<installDir>/<exe>
///   <root>/appcache/librarycache/<appid>/<looseIcon>.jpg      (square icon)
///   <root>/appcache/librarycache/<appid>/<hash>/library_600x900.jpg (capsule)
Directory _fakeSteam(
  Directory root, {
  required String appId,
  required String name,
  required String installDir,
  String exe = 'game.exe',
  String looseIcon = 'iconhash.jpg',
  List<int> iconBytes = const [1, 2, 3, 4],
  bool withCapsule = true,
}) {
  final steamapps = Directory(p.join(root.path, 'steamapps'))
    ..createSync(recursive: true);
  File(p.join(steamapps.path, 'appmanifest_$appId.acf')).writeAsStringSync('''
"AppState"
{
\t"appid"\t\t"$appId"
\t"name"\t\t"$name"
\t"installdir"\t\t"$installDir"
}
''');
  Directory(p.join(steamapps.path, 'common', installDir))
      .createSync(recursive: true);
  File(p.join(steamapps.path, 'common', installDir, exe))
      .writeAsStringSync('binary');

  final lc = Directory(p.join(root.path, 'appcache', 'librarycache', appId))
    ..createSync(recursive: true);
  File(p.join(lc.path, looseIcon)).writeAsBytesSync(iconBytes);
  if (withCapsule) {
    final sub = Directory(p.join(lc.path, 'deadbeef'))..createSync();
    File(p.join(sub.path, 'library_600x900.jpg'))
        .writeAsBytesSync(const [9, 9, 9]);
  }
  return steamapps;
}

void main() {
  late Directory tmp;
  late Directory cacheDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('steamres');
    cacheDir = Directory(p.join(tmp.path, 'cache'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  SteamIconResolver resolverFor(List<Directory> roots) => SteamIconResolver(
        cacheDir: cacheDir,
        steamappsRoots: () => roots,
      );

  test('resolves appid, name and cached icon from install dir', () {
    final steamapps = _fakeSteam(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      appId: '3241660',
      name: 'R.E.P.O.',
      installDir: 'REPO',
      iconBytes: const [10, 20, 30, 40],
    );
    final art = resolverFor([steamapps]).resolveByInstallDir('REPO');

    expect(art, isNotNull);
    expect(art!.appId, '3241660');
    expect(art.name, 'R.E.P.O.');
    expect(File(art.iconPath).existsSync(), isTrue);
    // The cached file is a copy of the loose square icon, not the capsule.
    expect(File(art.iconPath).readAsBytesSync(), const [10, 20, 30, 40]);
    expect(p.isWithin(cacheDir.path, art.iconPath), isTrue);
  });

  test('install-dir match is case- and punctuation-insensitive', () {
    final steamapps = _fakeSteam(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      appId: '10',
      name: 'Game',
      installDir: 'Half-Life 2',
    );
    final r = resolverFor([steamapps]);
    // A running window owner name like "half life 2" (no hyphen) still hits.
    expect(r.resolveByInstallDir('half life 2')?.appId, '10');
  });

  test('resolves from a Windows exe path', () {
    final steamapps = _fakeSteam(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      appId: '3241660',
      name: 'R.E.P.O.',
      installDir: 'REPO',
      exe: 'REPO.exe',
    );
    final art = resolverFor([steamapps]).resolveByExePath(
        r'C:\Program Files (x86)\Steam\steamapps\common\REPO\REPO.exe');
    expect(art?.appId, '3241660');
  });

  test('prefers the loose square icon over the capsule art', () {
    final steamapps = _fakeSteam(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      appId: '55',
      name: 'Cap',
      installDir: 'Cap',
      looseIcon: 'sq.jpg',
      iconBytes: const [7, 7],
    );
    final art = resolverFor([steamapps]).resolveByInstallDir('Cap');
    expect(File(art!.iconPath).readAsBytesSync(), const [7, 7]);
  });

  test('falls back to capsule art when no loose icon exists', () {
    final root = Directory(p.join(tmp.path, 'root'))..createSync();
    final steamapps = Directory(p.join(root.path, 'steamapps'))
      ..createSync(recursive: true);
    File(p.join(steamapps.path, 'appmanifest_77.acf')).writeAsStringSync(
        '"AppState"{"appid" "77" "name" "OnlyCap" "installdir" "OnlyCap"}');
    final sub = Directory(
        p.join(root.path, 'appcache', 'librarycache', '77', 'hh'))
      ..createSync(recursive: true);
    File(p.join(sub.path, 'library_600x900.jpg'))
        .writeAsBytesSync(const [5, 5, 5]);

    final art = resolverFor([steamapps]).resolveByInstallDir('OnlyCap');
    expect(art, isNotNull);
    expect(File(art!.iconPath).readAsBytesSync(), const [5, 5, 5]);
  });

  test('returns null for an unknown install dir', () {
    final steamapps = _fakeSteam(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      appId: '1',
      name: 'A',
      installDir: 'A',
    );
    expect(resolverFor([steamapps]).resolveByInstallDir('Nope'), isNull);
  });

  test('returns null when the game has no cached art at all', () {
    final root = Directory(p.join(tmp.path, 'root'))..createSync();
    final steamapps = Directory(p.join(root.path, 'steamapps'))
      ..createSync(recursive: true);
    File(p.join(steamapps.path, 'appmanifest_9.acf')).writeAsStringSync(
        '"AppState"{"appid" "9" "name" "NoArt" "installdir" "NoArt"}');
    // No appcache/librarycache dir at all.
    expect(resolverFor([steamapps]).resolveByInstallDir('NoArt'), isNull);
  });

  test('finds games across extra libraryfolders.vdf libraries', () {
    final main = Directory(p.join(tmp.path, 'main'))..createSync();
    final mainSteamapps = Directory(p.join(main.path, 'steamapps'))
      ..createSync(recursive: true);
    final lib2 = Directory(p.join(tmp.path, 'lib2'))..createSync();
    _fakeSteam(lib2,
        appId: '200', name: 'Far', installDir: 'FarGame');
    // libraryfolders.vdf in the main library points at lib2.
    File(p.join(mainSteamapps.path, 'libraryfolders.vdf')).writeAsStringSync('''
"libraryfolders"
{
\t"0"
\t{
\t\t"path"\t\t"${lib2.path.replaceAll(r'\', r'\\')}"
\t}
}
''');
    final art = resolverFor([mainSteamapps]).resolveByInstallDir('FarGame');
    expect(art?.appId, '200');
  });

  test('steamGameByInstallDir confirms installed games, even without art', () {
    final root = Directory(p.join(tmp.path, 'root'))..createSync();
    final steamapps = Directory(p.join(root.path, 'steamapps'))
      ..createSync(recursive: true);
    // A manifest but NO librarycache art at all.
    File(p.join(steamapps.path, 'appmanifest_9.acf')).writeAsStringSync(
        '"AppState"{"appid" "9" "name" "NoArt Game" "installdir" "NoArt"}');
    final r = resolverFor([steamapps]);

    final game = r.steamGameByInstallDir('noart');
    expect(game, isNotNull);
    expect(game!.appId, '9');
    expect(game.name, 'NoArt Game');
    // It's a confirmed game (the "is this a game?" signal) even though there's
    // no icon to resolve.
    expect(r.resolveByInstallDir('noart'), isNull);
  });

  test('steamGameByInstallDir returns null for a non-game process', () {
    final steamapps = _fakeSteam(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      appId: '1',
      name: 'A',
      installDir: 'A',
    );
    // explorer.exe / steamwebhelper.exe have no manifest -> not a game.
    expect(resolverFor([steamapps]).steamGameByInstallDir('explorer'), isNull);
  });

  test('memoizes: repeated resolves return the same cached path', () {
    final steamapps = _fakeSteam(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      appId: '42',
      name: 'Mem',
      installDir: 'Mem',
    );
    final r = resolverFor([steamapps]);
    final a = r.resolveByInstallDir('Mem');
    final b = r.resolveByInstallDir('mem');
    expect(a!.iconPath, b!.iconPath);
  });
}
