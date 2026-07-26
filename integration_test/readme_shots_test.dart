import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/clip/thumbnail_cache.dart';
import 'package:rewind/src/clip/thumbnail_generator.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/obs/display_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/shell.dart';
import 'package:rewind/src/ui/theme.dart';

import '../test/fakes/fake_capture_engine.dart';

/// Product screenshots for README.md and the hosted page.
///
/// Deliberately NOT the design-review tours (`ui_tour_test.dart`,
/// `redesign_tour_test.dart`), which seed synthetic fixtures. This one points
/// at a REAL clip library so the grid shows real gameplay thumbnails —
/// synthetic fixtures render grey placeholder tiles, which is fine for judging
/// layout and useless for showing anyone what the app is.
///
/// Why not just capture the real window with `screencapture`? Because that
/// photographs the whole desktop — wallpaper, dock, other windows, the
/// browser tabs behind it — and it can only be taken when nobody is using the
/// machine. This renders the same UI with none of that, at a fixed size, and
/// can be re-run after any UI change.
///
/// Point it at a library with content:
///
/// ```bash
/// flutter test integration_test/readme_shots_test.dart -d macos \
///   --dart-define=LIB_DIR=$HOME/Movies/Rewind \
///   --dart-define=SHOT_DIR=readme
/// ```
///
/// With no LIB_DIR the tour SKIPS rather than shipping empty screenshots —
/// a blank grid is worse than no image.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const libDir = String.fromEnvironment('LIB_DIR');
  const shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: 'readme');
  final boundaryKey = GlobalKey();

  // 16:10, and wide enough that the rail shows its labels (the layout
  // collapses to icons below navRailCompactBelow). Retina via pixelRatio: 2,
  // so the PNGs land at 2560x1600 — plenty for a hero image, and the same
  // geometry on every machine.
  const size = Size(1280, 800);

  setUp(() {
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

  /// The real library, loaded off disk exactly as `main.dart` loads it.
  Future<Shell> realShell() async {
    final dir = Directory(libDir);
    final library = await ClipLibrary.load(dir);
    final stats = await MatchStatsStore.load(dir);

    final settings = AppSettings();
    // Register the games the library actually contains, so the rail lists
    // them instead of showing a single Desktop row.
    for (final gameId in library.all.map((c) => c.gameId).toSet()) {
      settings.setConfig(GameConfig(gameId: gameId));
    }

    final coordinator = ClipCoordinator(
      registry: GameRegistry(sources: []),
      library: library,
      storage: StorageManager(library),
      settings: settings,
      outDir: dir.path,
      engine: FakeCaptureEngine(),
      matchStats: stats,
    );
    // Shown ARMED with a game live: the state the app is in while it's
    // actually doing its job, which is what a screenshot should show.
    final gameIds = settings.allConfigs.map((c) => c.gameId).toList();
    if (gameIds.isNotEmpty) {
      final live = gameIds.firstWhere((g) => g != 'desktop',
          orElse: () => gameIds.first);
      coordinator.activeGameIds.value = {live};
      coordinator.activeGame.value = live;
    }

    return Shell(
      coordinator: coordinator,
      library: library,
      hotkeyLabel: 'Alt+F10',
      bufferActive: ValueNotifier<bool>(true),
      bufferAutoPaused: ValueNotifier<bool>(false),
      displays: displays,
      onSettingsChanged: (_) async {},
      onOpenClipsFolder: () {},
      onCleanUpStorage: () async => const [],
      // The REAL generator: these thumbnails are the whole point. FFmpeg is
      // present on-device (the player tour already relies on it), and most
      // clips will already have a cached .thumbs/*.jpg to load straight off
      // disk.
      thumbnails: ThumbnailCache(FfmpegThumbnailGenerator()),
    );
  }

  /// Thumbnails resolve through a FutureBuilder per tile, so a single pump
  /// captures placeholders. Pump in slices until the frames settle.
  Future<void> letThumbnailsLand(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('readme — all clips', (t) async {
    if (libDir.isEmpty) {
      markTestSkipped('pass --dart-define=LIB_DIR=<clips dir>');
      return;
    }
    await t.pumpWidget(frame(await realShell()));
    await letThumbnailsLand(t);
    await shoot('01-all-clips');
  });

  testWidgets('readme — a game hub', (t) async {
    if (libDir.isEmpty) {
      markTestSkipped('pass --dart-define=LIB_DIR=<clips dir>');
      return;
    }
    await t.pumpWidget(frame(await realShell()));
    await t.pump(const Duration(milliseconds: 400));

    // First non-desktop game row in the rail.
    final rows = find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('navGame:') &&
        (w.key as ValueKey<String>).value != 'navGame:desktop');
    if (rows.evaluate().isEmpty) {
      markTestSkipped('no game rows in this library');
      return;
    }
    await t.tap(rows.first);
    await letThumbnailsLand(t);
    await shoot('02-game-hub');
  });

  testWidgets('readme — capture settings', (t) async {
    if (libDir.isEmpty) {
      markTestSkipped('pass --dart-define=LIB_DIR=<clips dir>');
      return;
    }
    await t.pumpWidget(frame(await realShell()));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const ValueKey('navItem:settings')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    await shoot('04-settings');
  });

  testWidgets('readme — the recorder', (t) async {
    if (libDir.isEmpty) {
      markTestSkipped('pass --dart-define=LIB_DIR=<clips dir>');
      return;
    }
    await t.pumpWidget(frame(await realShell()));
    await letThumbnailsLand(t);
    await t.tap(find.byKey(const ValueKey('recorderButton')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await shoot('03-recorder');
  });
}
