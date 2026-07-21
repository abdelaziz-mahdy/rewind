import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/games/steam_icon_backfill.dart';
import 'package:rewind/src/games/steam_icon_resolver.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';

Directory _fakeSteamGame(Directory parent, String appId, String name,
    String installDir) {
  final root = Directory(p.join(parent.path, 'home-$appId'))..createSync();
  final steamapps = Directory(p.join(root.path, 'steamapps'))
    ..createSync(recursive: true);
  File(p.join(steamapps.path, 'appmanifest_$appId.acf')).writeAsStringSync(
      '"AppState"{"appid" "$appId" "name" "$name" "installdir" "$installDir"}');
  final lc = Directory(p.join(root.path, 'appcache', 'librarycache', appId))
    ..createSync(recursive: true);
  File(p.join(lc.path, 'icon.jpg')).writeAsBytesSync(const [1, 2, 3]);
  return steamapps;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('backfill'));
  tearDown(() => tmp.deleteSync(recursive: true));

  SteamIconResolver resolverFor(List<Directory> roots) => SteamIconResolver(
        cacheDir: Directory(p.join(tmp.path, 'cache')),
        steamappsRoots: () => roots,
      );

  test('backfills icon + name for an iconless game that maps to Steam', () {
    final steamapps = _fakeSteamGame(tmp, '3241660', 'R.E.P.O.', 'REPO');
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: 'app:repo', displayName: 'REPO'));

    final changed = backfillSteamIcons(settings, resolverFor([steamapps]));

    expect(changed, 1);
    final cfg = settings.configFor('app:repo');
    expect(cfg.iconPath, isNotNull);
    expect(File(cfg.iconPath!).existsSync(), isTrue);
    // Steam's proper name filled the empty displayName override.
    expect(cfg.displayName, isNotNull);
  });

  test('leaves a game that already has an icon untouched', () {
    final steamapps = _fakeSteamGame(tmp, '3241660', 'R.E.P.O.', 'REPO');
    final settings = AppSettings()
      ..setConfig(GameConfig(
          gameId: 'app:repo', displayName: 'REPO', iconPath: '/existing.icns'));

    final changed = backfillSteamIcons(settings, resolverFor([steamapps]));

    expect(changed, 0);
    expect(settings.configFor('app:repo').iconPath, '/existing.icns');
  });

  test('leaves a non-Steam game on its monogram (no match, no change)', () {
    final steamapps = _fakeSteamGame(tmp, '10', 'Other', 'Other');
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: 'app:mystery', displayName: 'Mystery'));

    final changed = backfillSteamIcons(settings, resolverFor([steamapps]));

    expect(changed, 0);
    expect(settings.configFor('app:mystery').iconPath, isNull);
  });

  test('matches via the process needle when displayName does not', () {
    final steamapps = _fakeSteamGame(tmp, '55', 'Capsule', 'CoolGame');
    final settings = AppSettings()
      ..setConfig(GameConfig(
          gameId: 'app:x', displayName: 'Nickname', processMatch: 'CoolGame'));

    final changed = backfillSteamIcons(settings, resolverFor([steamapps]));

    expect(changed, 1);
    expect(settings.configFor('app:x').iconPath, isNotNull);
  });
}
