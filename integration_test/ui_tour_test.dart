import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/clip_trimmer.dart';
import 'package:rewind/src/clip/filmstrip.dart';
import 'package:rewind/src/clip/match_export.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/clip/thumbnail_cache.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/supported_games_screen.dart';
import 'package:rewind/src/ui/all_clips_screen.dart';
import 'package:rewind/src/ui/clip_sessions.dart';
import 'package:rewind/src/ui/match_clips_screen.dart';
import 'package:rewind/src/ui/onboarding_screen.dart';
import 'package:rewind/src/ui/player_screen.dart';
import 'package:rewind/src/ui/settings_screen.dart';
import 'package:rewind/src/ui/theme.dart';

import '../test/fakes/fake_capture_engine.dart';
import '../test/fakes/fake_thumbnail_generator.dart';

/// A visual tour of Rewind's key screens on the real macOS app. macOS's
/// integration_test plugin doesn't implement the `captureScreenshot`
/// channel, so each screen is wrapped in a RepaintBoundary and captured
/// with `toImage` (pure Dart, real GPU on the device) and written to
/// `screenshots/<name>.png`. Not an assertion suite — the screenshots ARE
/// the artifact.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The real main() does this before any media_kit Player is built; the
  // player trim tour needs it too.
  MediaKit.ensureInitialized();

  final boundaryKey = GlobalKey();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_tour'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> shoot(String name) async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('screenshots/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  }

  Widget frame(Widget child, {double height = 860}) => RepaintBoundary(
        key: boundaryKey,
        child: SizedBox(
          width: 1280,
          height: height,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: rewindTheme(),
            // A Scaffold supplies the dark scaffoldBackgroundColor that the
            // shell provides in the real app — screens like AllClipsScreen
            // are just a Column and render on whatever is behind them.
            home: Scaffold(body: child),
          ),
        ),
      );

  Clip clip(String name, GameEventKind kind, DateTime at, {String? label}) =>
      Clip(
        path: '${tmp.path}/$name.mp4',
        gameId: 'league_of_legends',
        event: kind,
        createdAt: at,
        sizeBytes: 40 * 1024 * 1024,
        eventLabel: label,
      );

  testWidgets('settings — capture page (audio, mic meter, echo tip)',
      (t) async {
    final settings = AppSettings(captureMicrophone: true);
    await t.pumpWidget(frame(SettingsScreen(
      settings: settings,
      onChanged: (_) async {},
      displays: const [],
      audioLevels: () =>
          '{"mic_peak_db":-12.0,"mic_mag_db":-18.0,"game_peak_db":-26.0,'
          '"game_mag_db":-32.0}',
      onClose: () {},
    )));
    await t.pump(const Duration(milliseconds: 300));
    await shoot('01-settings-capture');

    // Scroll down to the mic controls + test meter and open the test so
    // the target band renders populated.
    final testBtn = find.byKey(const ValueKey('micTestButton'));
    await t.scrollUntilVisible(testBtn, 300,
        scrollable: find.byType(Scrollable).first);
    await t.tap(testBtn);
    await t.pump(const Duration(milliseconds: 300));
    await t.scrollUntilVisible(find.byKey(const ValueKey('micTestHint')), 200,
        scrollable: find.byType(Scrollable).first);
    await t.pump(const Duration(milliseconds: 200));
    await shoot('01b-settings-mic-meter');
  });

  testWidgets('all clips — session feed with tiles', (t) async {
    final library = ClipLibrary(clipsDir: tmp);
    final base = DateTime.now();
    for (var i = 0; i < 4; i++) {
      library.add(clip(
          'clip$i',
          i.isEven ? GameEventKind.kill : GameEventKind.pentaKill,
          base.subtract(Duration(minutes: i * 3)),
          label: i == 0 ? 'Trimmed' : null));
    }
    final cache = ThumbnailCache(FakeThumbnailGenerator());
    await t.pumpWidget(frame(AllClipsScreen(
      library: library,
      hotkeyLabel: 'Alt+F10',
      onOpenClipsFolder: () {},
      thumbnails: cache,
    )));
    await t.pump(const Duration(milliseconds: 500));
    await shoot('02-all-clips');
  });

  testWidgets('all clips — first-run empty state', (t) async {
    final library = ClipLibrary(clipsDir: tmp);
    await t.pumpWidget(frame(AllClipsScreen(
      library: library,
      hotkeyLabel: 'Alt+F10',
      onOpenClipsFolder: () {},
    )));
    await t.pump(const Duration(milliseconds: 300));
    await shoot('03-all-clips-empty');
  });

  testWidgets('match screen — relocated Watch/Export actions', (t) async {
    final library = ClipLibrary(clipsDir: tmp);
    final start = DateTime.now().subtract(const Duration(minutes: 22));
    const kinds = [
      GameEventKind.kill,
      GameEventKind.doubleKill,
      GameEventKind.tripleKill,
      GameEventKind.quadraKill,
      GameEventKind.pentaKill,
    ];
    final clips = [
      for (var i = 0; i < kinds.length; i++)
        clip('m$i', kinds[i], start.add(Duration(minutes: i * 4)))
    ];
    for (final c in clips) {
      library.add(c);
    }
    final session = ClipSession(startedAt: start, clips: clips);
    final stats = MatchStats(
      gameId: 'league_of_legends',
      startedAt: start,
      kills: 7,
      deaths: 3,
      assists: 12,
      result: MatchResult.win,
    );
    await t.pumpWidget(frame(MatchClipsScreen(
      session: session,
      matchLabel: 'MATCH · 22 MIN AGO · 5 CLIPS',
      stats: stats,
      library: library,
      thumbnails: ThumbnailCache(FakeThumbnailGenerator()),
      exporter: FfmpegMatchExporter(),
    )));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('04-match-screen');
  });

  testWidgets('supported games — running-now add section', (t) async {
    final library = ClipLibrary(clipsDir: tmp);
    final settings = AppSettings();
    final coordinator = ClipCoordinator(
      registry: GameRegistry(),
      library: library,
      storage: StorageManager(library),
      settings: settings,
      outDir: tmp.path,
    );
    await t.pumpWidget(frame(SupportedGamesScreen(
      coordinator: coordinator,
      library: library,
      onSettingsChanged: (_) async {},
      onOpenGame: (_) {},
      listApps: () => const [
        AppInfo(
            bundleId: 'com.riotgames.valorant',
            name: 'VALORANT',
            pid: 10,
            windowId: 1),
        AppInfo(bundleId: '', name: 'PenguinHotel.exe', pid: 11, windowId: 2),
        AppInfo(
            bundleId: 'com.spotify.client',
            name: 'Spotify',
            pid: 12,
            windowId: 3),
      ],
    )));
    await t.pump(const Duration(milliseconds: 300));
    // Scroll to the Running now section at the bottom.
    await t.scrollUntilVisible(find.text('Running now'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pump(const Duration(milliseconds: 200));
    await shoot('07-supported-games');
  });

  testWidgets('onboarding — first-run welcome', (t) async {
    await t.pumpWidget(frame(OnboardingScreen(
      settings: AppSettings(),
      onChanged: (_) async {},
      onDone: () {},
      engine: FakeCaptureEngine()..screenPermissionGranted = true,
    )));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('06-onboarding');
  });

  testWidgets('player — trim mode with real FFmpeg filmstrip', (t) async {
    // Generate a real 8-second test clip so media_kit can play it and the
    // filmstrip generator has actual frames to sample (both plugins are
    // live on the device).
    final videoPath = '${tmp.path}/testclip.mp4';
    await FFmpegKit.executeWithArguments([
      '-f',
      'lavfi',
      '-i',
      'testsrc=duration=8:size=1280x720:rate=30',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      '-y',
      videoPath,
    ]);
    if (!File(videoPath).existsSync()) {
      // If ffmpeg couldn't produce a clip, skip rather than fail the tour.
      return;
    }

    final library = ClipLibrary(clipsDir: tmp);
    final theClip = clip('testclip', GameEventKind.pentaKill, DateTime.now());
    library.add(theClip);

    await t.pumpWidget(frame(PlayerScreen(
      clip: theClip,
      library: library,
      trimmer: FfmpegKitClipTrimmer(),
      filmstrip: FfmpegFilmstripGenerator(),
    )));

    // Wait (bounded) for media_kit to report a duration so the trim button
    // becomes available.
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 250));
      if (find.byKey(const ValueKey('trimButton')).evaluate().isNotEmpty) {
        break;
      }
    }
    final trimBtn = find.byKey(const ValueKey('trimButton'));
    if (trimBtn.evaluate().isEmpty) {
      // media_kit never reported a duration on this runner — capture what
      // we have rather than failing.
      await shoot('05-player-no-trim');
      return;
    }
    await t.tap(trimBtn);
    // Let the filmstrip generate + decode.
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
    await shoot('05-player-trim');
  });
}
