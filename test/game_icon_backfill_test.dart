import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/games/exe_icon_resolver.dart';
import 'package:rewind/src/games/game_icon_backfill.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/capture_app_match.dart' show gameIdForApp;

/// A Wine game's icon can only be resolved while it RUNS — its pid is what
/// leads to the exe the icon lives in. Resolution used to happen on exactly
/// one of the three paths that learn a game, so a game learned either other
/// way kept a letter monogram forever.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_icons'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  /// A Wine app: no bundle id, which is what routes it to the exe reader.
  AppInfo wineApp(String name, {int pid = 42}) =>
      AppInfo(bundleId: '', name: name, pid: pid);

  /// An ExeIconResolver whose exe lookup is stubbed, so no real process or
  /// CrossOver bottle is needed.
  ExeIconResolver resolverYielding(String? iconPath) {
    final exe = File('${tmp.path}/Game.exe')..writeAsBytesSync(const [0]);
    return ExeIconResolver(
      cacheDir: Directory('${tmp.path}/cache'),
      exePathForPid: (_) async => iconPath == null ? null : exe.path,
    );
  }

  test('a running game with no icon gets nothing when nothing resolves',
      () async {
    final app = wineApp('PenguinHotel-Win64-Shipping');
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: gameIdForApp(app)));

    final changed = await backfillRunningGameIcons(
      settings,
      [app],
      exeResolver: resolverYielding(null),
    );

    expect(changed, 0);
    expect(settings.allConfigs.first.iconPath, isNull);
  });

  test('a game that already has an icon is left alone', () async {
    final app = wineApp('PenguinHotel-Win64-Shipping');
    final settings = AppSettings()
      ..setConfig(GameConfig(
        gameId: gameIdForApp(app),
        iconPath: '/tmp/already.png',
      ));

    final changed = await backfillRunningGameIcons(settings, [app]);

    expect(changed, 0);
    expect(settings.allConfigs.first.iconPath, '/tmp/already.png');
  });

  // Auto-resolution is exactly what a user overrides when the resolved icon
  // is wrong. Resolving over their pick would undo the fix they came for.
  test('a user-chosen icon is never overwritten', () async {
    final app = wineApp('PenguinHotel-Win64-Shipping');
    final settings = AppSettings()
      ..setConfig(GameConfig(
        gameId: gameIdForApp(app),
        iconPath: '/tmp/mine.png',
        iconIsUserChosen: true,
      ));

    await backfillRunningGameIcons(settings, [app]);

    expect(settings.allConfigs.first.iconPath, '/tmp/mine.png');
    expect(settings.allConfigs.first.iconIsUserChosen, isTrue);
  });

  test('a configured game that is NOT running is skipped', () async {
    final running = wineApp('SomethingElse');
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: 'app:penguinhotel_win64_shipping'));

    final changed = await backfillRunningGameIcons(
      settings,
      [running],
      exeResolver: resolverYielding('/tmp/whatever.png'),
    );

    expect(changed, 0);
  });

  test('no configured games at all is a cheap no-op', () async {
    expect(
      await backfillRunningGameIcons(AppSettings(), [wineApp('Anything')]),
      0,
    );
  });

  test('a normal macOS app is left to its bundle icon, not the exe reader',
      () async {
    const app = AppInfo(bundleId: 'com.example.game', name: 'Game', pid: 7);
    final settings = AppSettings()
      ..setConfig(GameConfig(gameId: gameIdForApp(app)));

    final changed = await backfillRunningGameIcons(
      settings,
      [app],
      exeResolver: resolverYielding('/tmp/exe.png'),
    );

    // iconForApp refuses a bundled app outright — its .icns is already the
    // better source, read through AppInfo.iconPath elsewhere.
    expect(changed, 0);
  });
}
