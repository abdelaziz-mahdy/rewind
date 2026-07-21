import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/games/steam_icon_resolver.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/supported_games_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import '../fakes/fake_capture_engine.dart';

Widget _app(Widget child) =>
    MaterialApp(theme: rewindTheme(), home: Scaffold(body: child));

/// The catalog is 14 rows tall (13 catalog games + the merged League row) —
/// wide enough default viewports still clip the list, so widen the test
/// surface (matches `game_hub_screen_test.dart`'s identical helper/reason).
Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1200, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(child);
}

void main() {
  late Directory tmp;
  late ClipLibrary library;
  late ClipCoordinator coordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_supported_games');
    library = ClipLibrary(clipsDir: tmp);
    coordinator = ClipCoordinator(
      registry: GameRegistry(sources: []),
      library: library,
      storage: StorageManager(library),
      settings: AppSettings(),
      outDir: tmp.path,
      engine: FakeCaptureEngine(),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Clip clip(String path, String gameId, DateTime createdAt) => Clip(
        path: '${tmp.path}/$path.mp4',
        gameId: gameId,
        event: GameEventKind.manual,
        createdAt: createdAt,
        sizeBytes: 1024,
      );

  SupportedGamesScreen screen({
    Future<void> Function(AppSettings)? onSettingsChanged,
    ValueChanged<String>? onOpenGame,
    List<AppInfo> Function()? listApps,
    SteamIconResolver? steamResolver,
  }) =>
      SupportedGamesScreen(
        coordinator: coordinator,
        library: library,
        onSettingsChanged: onSettingsChanged ?? (_) async {},
        onOpenGame: onOpenGame ?? (_) {},
        listApps: listApps,
        steamResolver: steamResolver,
      );

  Finder row(String gameId) => find.byKey(ValueKey('supportedGameRow:$gameId'));
  Finder inRow(String gameId, Finder f) =>
      find.descendant(of: row(gameId), matching: f);

  testWidgets(
      'renders every catalog game plus the merged League row exactly '
      'once', (t) async {
    await _pump(t, _app(screen()));

    // The League vendor row (merged), not a duplicate catalog entry.
    expect(row('league_of_legends'), findsOneWidget);
    expect(row('app:league_of_legends'), findsNothing);
    expect(find.text('League of Legends'), findsOneWidget);
    expect(inRow('league_of_legends', find.textContaining('Live Client API')),
        findsOneWidget);

    // A sampling of the plain process-detection catalog rows.
    expect(row('app:cs2'), findsOneWidget);
    expect(
        inRow('app:cs2', find.textContaining('Process: cs2')), findsOneWidget);
    expect(row('app:dota2'), findsOneWidget);
    expect(row('app:valorant'), findsOneWidget);
  });

  testWidgets('an unconfigured, clipless, inactive game shows an Add button',
      (t) async {
    await _pump(t, _app(screen()));

    expect(inRow('app:cs2', find.byKey(const ValueKey('addGameButton'))),
        findsOneWidget);
    expect(inRow('app:cs2', find.text('IN YOUR LIBRARY')), findsNothing);
    expect(inRow('app:cs2', find.text('RUNNING')), findsNothing);
  });

  testWidgets('tapping Add creates a GameConfig and fires onSettingsChanged',
      (t) async {
    final calls = <AppSettings>[];
    await _pump(t, _app(screen(onSettingsChanged: (s) async => calls.add(s))));

    await t.tap(inRow('app:cs2', find.byKey(const ValueKey('addGameButton'))));
    await t.pump();

    expect(calls, isNotEmpty);
    expect(coordinator.settings.allConfigs.map((c) => c.gameId),
        contains('app:cs2'));
    // The row updates immediately without waiting on an external listenable.
    expect(inRow('app:cs2', find.text('IN YOUR LIBRARY')), findsOneWidget);
    expect(inRow('app:cs2', find.byKey(const ValueKey('addGameButton'))),
        findsNothing);
  });

  testWidgets('a game with an existing config shows "In your library"',
      (t) async {
    coordinator.settings.setConfig(GameConfig(gameId: 'app:valorant'));
    await _pump(t, _app(screen()));

    expect(inRow('app:valorant', find.text('IN YOUR LIBRARY')), findsOneWidget);
  });

  testWidgets('a game with clips but no config shows "In your library"',
      (t) async {
    library.add(clip('a', 'app:dota2', DateTime(2026, 1, 1)));
    await _pump(t, _app(screen()));

    expect(inRow('app:dota2', find.text('IN YOUR LIBRARY')), findsOneWidget);
  });

  testWidgets('an active gameId shows "Running" instead of "In your library"',
      (t) async {
    coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
    coordinator.activeGameIds.value = {'app:cs2'};
    await _pump(t, _app(screen()));

    expect(inRow('app:cs2', find.text('RUNNING')), findsOneWidget);
    expect(inRow('app:cs2', find.text('IN YOUR LIBRARY')), findsNothing);
  });

  testWidgets(
      "League's merged row shows Running when either of its two gameIds is "
      'active', (t) async {
    coordinator.settings.setConfig(GameConfig(gameId: 'league_of_legends'));
    coordinator.activeGameIds.value = {'app:league_of_legends'};
    await _pump(t, _app(screen()));

    expect(inRow('league_of_legends', find.text('RUNNING')), findsOneWidget);
  });

  testWidgets('tapping a configured row invokes the navigate callback',
      (t) async {
    coordinator.settings.setConfig(GameConfig(gameId: 'app:valorant'));
    final opened = <String>[];
    await _pump(t, _app(screen(onOpenGame: opened.add)));

    await t.tap(row('app:valorant'));
    await t.pump();

    expect(opened, ['app:valorant']);
  });

  testWidgets('tapping an active row invokes the navigate callback', (t) async {
    coordinator.activeGameIds.value = {'app:cs2'};
    final opened = <String>[];
    await _pump(t, _app(screen(onOpenGame: opened.add)));

    await t.tap(row('app:cs2'));
    await t.pump();

    expect(opened, ['app:cs2']);
  });

  testWidgets('the compliance footer note is shown', (t) async {
    await _pump(t, _app(screen()));
    expect(find.textContaining('never game memory'), findsOneWidget);
  });

  testWidgets(
      'Marvel Rivals appears as a process-detection row with a monogram '
      '(usesOfficialLogo false — no icon capture, per the descriptor)',
      (t) async {
    await _pump(t, _app(screen()));

    expect(row('app:marvel_rivals'), findsOneWidget);
    expect(find.text('Marvel Rivals'), findsOneWidget);
    expect(
        inRow('app:marvel_rivals',
            find.textContaining('Process: Marvel-Win64-Shipping')),
        findsOneWidget);
    // No iconPath is ever wired into this screen's GameTileAvatar for ANY
    // row (see game_tile_avatar.dart) — the monogram guarantee that matters
    // is tested against buildGameDirectory directly in
    // game_directory_test.dart ("Marvel Rivals never surfaces an iconPath").
  });
  group('Running now section', () {
    AppInfo app(String name, {String bundleId = 'com.x.app'}) =>
        AppInfo(bundleId: bundleId, name: name, pid: 42, windowId: 1);

    testWidgets('hidden without listApps wired', (t) async {
      await _pump(t, _app(screen()));
      expect(find.text('Running now'), findsNothing);
    });

    testWidgets('lists a running app with an Add button that learns it',
        (t) async {
      final persisted = <AppSettings>[];
      await _pump(
          t,
          _app(screen(
            listApps: () => [app('Penguin Hotel', bundleId: 'com.pg.hotel')],
            onSettingsChanged: (s) async => persisted.add(s),
          )));

      final rowFinder =
          find.byKey(const ValueKey('runningAppRow:app:penguin_hotel'));
      await t.scrollUntilVisible(rowFinder, 200,
          scrollable: find.byType(Scrollable).first);
      expect(rowFinder, findsOneWidget);

      await t.tap(find.descendant(of: rowFinder, matching: find.text('Add')));
      await t.pump();

      expect(persisted, isNotEmpty);
      final cfg = coordinator.settings.configFor('app:penguin_hotel');
      expect(cfg.processMatch, 'Penguin Hotel');
      expect(cfg.displayName, 'Penguin Hotel');
    });

    testWidgets('an already-learned app does not offer Add again', (t) async {
      coordinator.settings.setConfig(
          coordinator.settings.configFor('app:penguin_hotel')
            ..processMatch = 'Penguin Hotel');
      await _pump(
          t,
          _app(screen(
            listApps: () => [app('Penguin Hotel', bundleId: 'com.pg.hotel')],
          )));
      expect(find.byKey(const ValueKey('runningAppRow:app:penguin_hotel')),
          findsNothing);
    });

    // A Wine game (empty bundle id, no OS icon) resolved against a local
    // Steam library shows the real name + icon, and Add stores them so the
    // rail keeps the icon after the game stops.
    testWidgets('a Steam game resolves its real name and icon', (t) async {
      final steamRoot = _fakeSteamGame(tmp,
          appId: '3241660', name: 'R.E.P.O.', installDir: 'REPO');
      final resolver = SteamIconResolver(
        cacheDir: Directory('${tmp.path}/icons'),
        steamappsRoots: () => [steamRoot],
      );
      final persisted = <AppSettings>[];
      await _pump(
          t,
          _app(screen(
            // A running Wine app: bundle-less, window/exe named after the game.
            listApps: () => [app('REPO', bundleId: '')],
            steamResolver: resolver,
            onSettingsChanged: (s) async => persisted.add(s),
          )));

      final rowFinder = find.byKey(const ValueKey('runningAppRow:app:repo'));
      await t.scrollUntilVisible(rowFinder, 200,
          scrollable: find.byType(Scrollable).first);

      // Steam's proper name, not the bare "REPO", and a real icon image.
      expect(find.descendant(of: rowFinder, matching: find.text('R.E.P.O.')),
          findsOneWidget);
      expect(find.descendant(of: rowFinder, matching: find.byType(Image)),
          findsOneWidget);

      await t.tap(find.descendant(of: rowFinder, matching: find.text('Add')));
      await t.pump();

      final cfg = coordinator.settings.configFor('app:repo');
      expect(cfg.displayName, 'R.E.P.O.');
      expect(cfg.iconPath, isNotNull);
      expect(File(cfg.iconPath!).existsSync(), isTrue);
    });
  });
}

/// Minimal on-disk Steam layout for one game under [parent]; returns the
/// `steamapps` dir to hand to [SteamIconResolver.steamappsRoots].
Directory _fakeSteamGame(
  Directory parent, {
  required String appId,
  required String name,
  required String installDir,
}) {
  final root = Directory('${parent.path}/steamhome')..createSync();
  final steamapps = Directory('${root.path}/steamapps')
    ..createSync(recursive: true);
  File('${steamapps.path}/appmanifest_$appId.acf').writeAsStringSync(
      '"AppState" { "appid" "$appId" "name" "$name" "installdir" "$installDir" }');
  final lc = Directory('${root.path}/appcache/librarycache/$appId')
    ..createSync(recursive: true);
  File('${lc.path}/icon.jpg').writeAsBytesSync(const [1, 2, 3, 4]);
  return steamapps;
}
