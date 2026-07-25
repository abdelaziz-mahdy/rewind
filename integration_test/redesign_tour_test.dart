import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/clip/thumbnail_cache.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/obs/display_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/shell.dart';
import 'package:rewind/src/ui/theme.dart';

import '../test/fakes/fake_capture_engine.dart';
import '../test/fakes/fake_thumbnail_generator.dart';

/// Side-by-side screenshots of the SHELL for design review.
///
/// Deliberately separate from `ui_tour_test.dart`, and deliberately written
/// against only the API surface that exists on BOTH the pre- and
/// post-broadcast-deck trees, so the exact same file can be run on either
/// branch and the two output sets compared honestly. That means: no
/// `TransportDeck` import, no new optional `AllClipsScreen` parameters, no
/// `SessionCard` — everything goes through `Shell`, which kept its full prop
/// list across the redesign precisely so `main.dart` (and this) needed no
/// edit.
///
/// macOS's integration_test plugin doesn't implement the `captureScreenshot`
/// channel, so each frame is wrapped in a RepaintBoundary and captured with
/// `toImage` — pure Dart, real GPU on the device, and no Screen Recording
/// permission involved (which is why this works where `screencapture` from a
/// terminal does not).
///
/// Output goes to `screenshots/<SHOT_DIR>/`; pass
/// `--dart-define=SHOT_DIR=before` (or `after`) when running.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: 'after');
  final boundaryKey = GlobalKey();

  late Directory tmp;

  /// Force a deterministic canvas.
  ///
  /// `pumpWidget` applies TIGHT constraints from the test surface, so a
  /// `SizedBox` inside `frame()` is silently ignored — the first run of this
  /// tour captured 1600x1200 and a later one 3024x1636 purely because the
  /// window differed. Screenshots meant for before/after comparison have to
  /// be the same size or the comparison is worthless, so pin the view here.
  const size = Size(1440, 900);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_redesign');
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = size * 2;
    view.devicePixelRatio = 2;
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
    tmp.deleteSync(recursive: true);
  });

  Future<void> shoot(String name) async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('screenshots/$shotDir/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  }

  Widget frame(Widget child) => RepaintBoundary(
        key: boundaryKey,
        child: SizedBox.fromSize(
          size: size,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: rewindTheme(),
            home: child,
          ),
        ),
      );

  const displays = [
    DisplayInfo(uuid: 'display-1', width: 3024, height: 1890, isMain: true),
  ];

  Clip clip(
    String name,
    String gameId,
    GameEventKind kind,
    DateTime at, {
    DateTime? sessionAt,
    int sizeBytes = 42 * 1024 * 1024,
  }) =>
      Clip(
        path: '${tmp.path}/$name.mp4',
        gameId: gameId,
        event: kind,
        createdAt: at,
        sizeBytes: sizeBytes,
        sessionAt: sessionAt,
      );

  /// A library + coordinator seeded with two League matches and a desktop
  /// session, so every screen has believable content — a screenshot of an
  /// empty app proves nothing about a design.
  ({ClipLibrary library, ClipCoordinator coordinator}) seeded() {
    final library = ClipLibrary(clipsDir: tmp);
    final settings = AppSettings();
    settings.setConfig(GameConfig(gameId: 'league_of_legends'));
    settings.setConfig(GameConfig(gameId: 'app:repo'));
    final stats = MatchStatsStore(dir: tmp);

    final now = DateTime.now();
    final matchA = now.subtract(const Duration(hours: 2));
    final matchB = now.subtract(const Duration(hours: 5));
    final desktop = now.subtract(const Duration(hours: 26));

    const aKinds = [
      GameEventKind.kill,
      GameEventKind.doubleKill,
      GameEventKind.pentaKill,
      GameEventKind.dragonKill,
    ];
    for (var i = 0; i < aKinds.length; i++) {
      library.add(clip('a$i', 'league_of_legends', aKinds[i],
          matchA.add(Duration(minutes: 4 + i * 5)),
          sessionAt: matchA));
    }
    for (var i = 0; i < 2; i++) {
      library.add(clip('b$i', 'league_of_legends', GameEventKind.kill,
          matchB.add(Duration(minutes: 6 + i * 7)),
          sessionAt: matchB));
    }
    library.add(clip('d0', 'desktop', GameEventKind.manual,
        desktop.add(const Duration(minutes: 3)),
        sessionAt: desktop, sizeBytes: 18 * 1024 * 1024));

    // Recorded match stats — what makes a hub read as a match history rather
    // than a pile of files.
    for (var i = 0; i < 8; i++) {
      stats.recordKill('league_of_legends', matchA);
    }
    for (var i = 0; i < 3; i++) {
      stats.recordDeath('league_of_legends', matchA);
    }
    stats.recordStatsUpdate('league_of_legends', matchA,
        assists: 11, creepScore: 174, wardScore: 12);
    stats.recordMatchInfo('league_of_legends', matchA,
        champion: 'Singed', gameMode: 'CHERRY');
    stats.recordOutcome('league_of_legends', matchA, MatchResult.win);

    for (var i = 0; i < 4; i++) {
      stats.recordKill('league_of_legends', matchB);
    }
    for (var i = 0; i < 7; i++) {
      stats.recordDeath('league_of_legends', matchB);
    }
    stats.recordStatsUpdate('league_of_legends', matchB,
        assists: 9, creepScore: 132, wardScore: 8);
    stats.recordMatchInfo('league_of_legends', matchB,
        champion: 'MasterYi', gameMode: 'CLASSIC');
    stats.recordOutcome('league_of_legends', matchB, MatchResult.loss);

    final coordinator = ClipCoordinator(
      registry: GameRegistry(sources: []),
      library: library,
      storage: StorageManager(library),
      settings: settings,
      outDir: tmp.path,
      engine: FakeCaptureEngine(),
      matchStats: stats,
    );
    // A live game, so the rail dot and the hub's status read "active" —
    // the state the design is really about.
    coordinator.activeGameIds.value = {'league_of_legends'};
    coordinator.activeGame.value = 'league_of_legends';
    return (library: library, coordinator: coordinator);
  }

  Widget shell(
    ({ClipLibrary library, ClipCoordinator coordinator}) s, {
    String? captureError,
  }) =>
      Shell(
        coordinator: s.coordinator,
        library: s.library,
        hotkeyLabel: 'Alt+F10',
        captureError: captureError,
        bufferActive: ValueNotifier<bool>(true),
        bufferAutoPaused: ValueNotifier<bool>(false),
        displays: displays,
        onSettingsChanged: (_) async {},
        onOpenClipsFolder: () {},
        thumbnails: ThumbnailCache(FakeThumbnailGenerator()),
      );

  testWidgets('shell — all clips', (t) async {
    await t.pumpWidget(frame(shell(seeded())));
    await t.pump(const Duration(milliseconds: 600));
    await shoot('01-shell-all-clips');
  });

  testWidgets('shell — recorder panel open', (t) async {
    await t.pumpWidget(frame(shell(seeded())));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const ValueKey('recorderButton')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await shoot('06-recorder-panel');
  });

  testWidgets('shell — game hub', (t) async {
    await t.pumpWidget(frame(shell(seeded())));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const ValueKey('navGame:league_of_legends')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    await shoot('02-shell-game-hub');
  });

  testWidgets('shell — settings, mid-match', (t) async {
    // The screen most likely to be opened DURING a game: the point of
    // interest is whether recording state survives being here.
    await t.pumpWidget(frame(shell(seeded())));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const ValueKey('navItem:settings')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    await shoot('03-shell-settings');
  });

  testWidgets('shell — first run, empty library', (t) async {
    final library = ClipLibrary(clipsDir: tmp);
    final coordinator = ClipCoordinator(
      registry: GameRegistry(sources: []),
      library: library,
      storage: StorageManager(library),
      settings: AppSettings(),
      outDir: tmp.path,
      engine: FakeCaptureEngine(),
    );
    await t
        .pumpWidget(frame(shell((library: library, coordinator: coordinator))));
    await t.pump(const Duration(milliseconds: 500));
    await shoot('04-shell-empty');
  });

  testWidgets('shell — capture permission error', (t) async {
    await t.pumpWidget(frame(
        shell(seeded(), captureError: 'Screen Recording permission denied')));
    await t.pump(const Duration(milliseconds: 500));
    await shoot('05-shell-capture-error');
  });

  /// Resizing is a first-class case, not an afterthought: this is a desktop
  /// app that lives beside a game, so it gets dragged narrow, parked on a
  /// laptop display, and stretched across an ultrawide. Every one of those is
  /// a real window, and a layout that only works at one width is broken.
  group('resizing', () {
    const widths = <String, Size>{
      'narrow': Size(820, 720), // half a laptop screen
      'laptop': Size(1280, 800),
      'wide': Size(2200, 1100), // a big display, or half an ultrawide
    };

    for (final w in widths.entries) {
      testWidgets('all clips @ ${w.key}', (t) async {
        final view =
            TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
        view.physicalSize = w.value * 2;
        await t.pumpWidget(RepaintBoundary(
          key: boundaryKey,
          child: SizedBox.fromSize(
            size: w.value,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: rewindTheme(),
              home: shell(seeded()),
            ),
          ),
        ));
        await t.pump(const Duration(milliseconds: 600));
        await shoot('10-allclips-${w.key}');
      });

      testWidgets('game hub @ ${w.key}', (t) async {
        final view =
            TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
        view.physicalSize = w.value * 2;
        await t.pumpWidget(RepaintBoundary(
          key: boundaryKey,
          child: SizedBox.fromSize(
            size: w.value,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: rewindTheme(),
              home: shell(seeded()),
            ),
          ),
        ));
        await t.pump(const Duration(milliseconds: 400));
        await t.tap(find.byKey(const ValueKey('navGame:league_of_legends')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 600));
        await shoot('11-hub-${w.key}');
      });
    }
  });

  /// Every Settings page, for the settings audit.
  group('settings pages', () {
    const pages = <String, String>{
      'Capture': 'settingsTab:Capture',
      'Hotkey': 'settingsTab:Hotkey',
      'Storage': 'settingsTab:Storage',
      'Steam': 'settingsTab:Steam',
      'About': 'settingsTab:About',
    };

    for (final page in pages.entries) {
      testWidgets('settings — ${page.key}', (t) async {
        await t.pumpWidget(frame(shell(seeded())));
        await t.pump(const Duration(milliseconds: 300));
        await t.tap(find.byKey(const ValueKey('navItem:settings')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        await t.tap(find.byKey(ValueKey(page.value)));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        await shoot('20-settings-${page.key.toLowerCase()}');
      });
    }

    testWidgets('settings — a game page', (t) async {
      await t.pumpWidget(frame(shell(seeded())));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const ValueKey('navItem:settings')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('League of Legends').last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await shoot('21-settings-game');
    });
  });
}
