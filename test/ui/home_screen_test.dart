import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/home_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import '../fakes/fake_capture_engine.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

void main() {
  late Directory tmp;
  late ClipLibrary library;
  late ClipCoordinator coordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_ui');
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

  HomeScreen home({String? error, ValueNotifier<bool>? bufferActive}) =>
      HomeScreen(
          coordinator: coordinator,
          library: library,
          captureError: error,
          bufferActive: bufferActive,
          hotkeyLabel: 'Alt+F10',
          onOpenSettings: () {});

  testWidgets('empty state shows hotkey hint', (t) async {
    await t.pumpWidget(_app(home()));
    expect(find.textContaining('Alt+F10'), findsOneWidget);
  });

  testWidgets('capture error hides the buffering indicator', (t) async {
    await t.pumpWidget(_app(home(error: 'libobs init failed')));
    expect(find.textContaining('Buffering'), findsNothing);
    expect(find.text('Capture unavailable'), findsOneWidget);
  });

  testWidgets('paused buffer shows Paused and stops claiming Buffering',
      (t) async {
    final active = ValueNotifier<bool>(true);
    await t.pumpWidget(_app(home(bufferActive: active)));
    expect(find.textContaining('Buffering'), findsOneWidget);
    active.value = false;
    await t.pump();
    expect(find.textContaining('Buffering'), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('clips render newest-first with event badge', (t) async {
    library.add(Clip(
        path: '${tmp.path}/a.mp4',
        gameId: 'desktop',
        event: GameEventKind.manual,
        createdAt: DateTime(2026, 7, 1),
        sizeBytes: 5 * 1024 * 1024));
    library.add(Clip(
        path: '${tmp.path}/b.mp4',
        gameId: 'league_of_legends',
        event: GameEventKind.pentaKill,
        createdAt: DateTime(2026, 7, 2),
        sizeBytes: 1024));
    await t.pumpWidget(_app(home()));
    expect(find.text('PENTA KILL'), findsOneWidget);
    expect(find.text('MANUAL'), findsOneWidget);
    // "newest-first" means clip b (created 2026-07-02) renders above
    // clip a (2026-07-01), not just that both are present somewhere.
    final pentaTop = t.getTopLeft(find.text('PENTA KILL')).dy;
    final manualTop = t.getTopLeft(find.text('MANUAL')).dy;
    expect(pentaTop, lessThan(manualTop));
  });

  testWidgets('library updates reactively when a clip is added', (t) async {
    await t.pumpWidget(_app(home()));
    library.add(Clip(
        path: '${tmp.path}/a.mp4',
        gameId: 'desktop',
        event: GameEventKind.manual,
        createdAt: DateTime(2026, 7, 1),
        sizeBytes: 1));
    await t.pump();
    expect(find.text('MANUAL'), findsOneWidget);
  });

  testWidgets('capture error shows banner and disables Save', (t) async {
    await t.pumpWidget(_app(home(error: 'libobs init failed')));
    expect(find.textContaining('libobs init failed'), findsOneWidget);
    final btn =
        t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save clip'));
    expect(btn.onPressed, isNull);
  });

  testWidgets('active game chip follows coordinator.activeGame', (t) async {
    await t.pumpWidget(_app(home()));
    expect(find.text('Desktop'), findsOneWidget);
    coordinator.activeGame.value = 'league_of_legends';
    await t.pump();
    expect(find.text('league_of_legends'), findsOneWidget);
  });

  testWidgets('a save error shows a SnackBar with the message', (t) async {
    await t.pumpWidget(_app(home()));
    coordinator.lastSaveError.value = 'disk full';
    await t.pump(); // schedule the SnackBar
    await t.pump(); // let it animate in
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets('the Logs button opens the Talker screen', (t) async {
    await t.pumpWidget(_app(home()));
    await t.tap(find.widgetWithIcon(IconButton, Icons.receipt_long_outlined));
    await t.pumpAndSettle();
    expect(find.text('Talker'), findsOneWidget);
  });

  testWidgets('rendering the status strip does not pre-seed a game config',
      (t) async {
    // Merely showing "Buffering · N s" must not insert a 'desktop' (or any
    // other) row into settings — that would leak into SettingsScreen's
    // per-game section before a game has ever actually been configured.
    await t.pumpWidget(_app(home()));
    expect(coordinator.settings.allConfigs, isEmpty);
  });
}
