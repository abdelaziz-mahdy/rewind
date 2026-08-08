import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/games/icon_store.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';

/// A game's icon used to be stored as a path into wherever it happened to
/// live — for a game on an external drive, a path that stops existing the
/// moment the drive is unplugged, dropping the rail back to a monogram.
void main() {
  late Directory tmp;
  late Directory cache;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_icons');
    cache = Directory(p.join(tmp.path, '.icons'))..createSync();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  File source(String name, {List<int> bytes = const [1, 2, 3]}) {
    final f = File(p.join(tmp.path, name));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  test('copies an external icon into the cache and repoints the game',
      () async {
    final icon = source('external/Big Walk.app/Contents/Resources/Icon.icns');
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: 'app:big_walk', iconPath: icon.path));

    final changed = await localizeGameIcons(settings, cache);

    expect(changed, 1);
    final stored = settings.allConfigs.single.iconPath!;
    expect(p.isWithin(cache.path, stored), isTrue);
    expect(File(stored).readAsBytesSync(), [1, 2, 3]);
    expect(p.extension(stored), '.icns', reason: 'keeps the format');

    // The original can now go away entirely.
    icon.deleteSync();
    expect(File(stored).existsSync(), isTrue);
  });

  test('an icon already in the cache is left alone', () async {
    final inCache = File(p.join(cache.path, 'steam-1.jpg'))
      ..writeAsBytesSync(const [9]);
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: 'app:x', iconPath: inCache.path));

    expect(await localizeGameIcons(settings, cache), 0);
    expect(settings.allConfigs.single.iconPath, inCache.path);
  });

  // The drive being unplugged is exactly when this runs and finds nothing —
  // it must not wipe the path, because the drive may come back.
  test('an unreachable source keeps its path for a later run', () async {
    final settings = AppSettings()
      ..setConfig(GameConfig(
          gameId: 'app:gone', iconPath: '/Volumes/unplugged/Game/icon.icns'));

    expect(await localizeGameIcons(settings, cache), 0);
    expect(settings.allConfigs.single.iconPath,
        '/Volumes/unplugged/Game/icon.icns');
  });

  test('a game with no icon is skipped', () async {
    final settings = AppSettings()..setConfig(GameConfig(gameId: 'app:none'));
    expect(await localizeGameIcons(settings, cache), 0);
  });

  // Keyed by game, so a reinstall elsewhere replaces its own icon instead of
  // leaving copies behind.
  test('re-localizing the same game overwrites its own copy', () async {
    final first = source('a/icon.icns', bytes: const [1]);
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: 'app:g', iconPath: first.path));
    await localizeGameIcons(settings, cache);
    final firstDest = settings.allConfigs.single.iconPath;

    final moved = source('b/icon.icns', bytes: const [2]);
    settings.setConfig(GameConfig(gameId: 'app:g', iconPath: moved.path));
    await localizeGameIcons(settings, cache);

    expect(settings.allConfigs.single.iconPath, firstDest);
    expect(File(firstDest!).readAsBytesSync(), [2]);
    expect(cache.listSync().whereType<File>().length, 1);
  });
}
