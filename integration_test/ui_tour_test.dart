import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/thumbnail_cache.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/all_clips_screen.dart';
import 'package:rewind/src/ui/settings_screen.dart';
import 'package:rewind/src/ui/theme.dart';

import '../test/fakes/fake_thumbnail_generator.dart';

/// A visual tour of Rewind's key screens on the real macOS app. macOS's
/// integration_test plugin doesn't implement the `captureScreenshot`
/// channel, so each screen is wrapped in a RepaintBoundary and captured
/// with `toImage` (pure Dart, real GPU on the device) and written to
/// `screenshots/<name>.png`. Not an assertion suite — the screenshots ARE
/// the artifact.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final boundaryKey = GlobalKey();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_tour'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> shoot(String name) async {
    final boundary = boundaryKey.currentContext!.findRenderObject()
        as RenderRepaintBoundary;
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
      library.add(clip('clip$i',
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
}
