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
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/shell.dart';
import 'package:rewind/src/ui/theme.dart';
import '../fakes/fake_capture_engine.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

void main() {
  late Directory tmp;
  late ClipLibrary library;
  late ClipCoordinator coordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_shell');
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

  Shell shell({
    String? error,
    ValueNotifier<bool>? bufferActive,
    VoidCallback? onOpenClipsFolder,
  }) =>
      Shell(
        coordinator: coordinator,
        library: library,
        captureError: error,
        // Idle by default: an un-paused buffer keeps the recorder deck's
        // pulsing dot ticking forever, which would hang `pumpAndSettle`
        // (matches status_strip_test.dart's own note on the same widget).
        bufferActive: bufferActive ?? ValueNotifier<bool>(false),
        hotkeyLabel: 'Alt+F10',
        onSettingsChanged: (_) async {},
        onOpenClipsFolder: onOpenClipsFolder ?? () {},
      );

  Clip clip(String path, String gameId, GameEventKind event, DateTime createdAt,
          {int sizeBytes = 1024}) =>
      Clip(
          path: '${tmp.path}/$path.mp4',
          gameId: gameId,
          event: event,
          createdAt: createdAt,
          sizeBytes: sizeBytes);

  Finder navItem(String id) => find.byKey(ValueKey('navItem:$id'));
  Finder navGame(String gameId) => find.byKey(ValueKey('navGame:$gameId'));

  // The event-kind filter chips can show the same uppercase badge text as a
  // clip tile (e.g. a "PENTA KILL" chip alongside a clip's "PENTA KILL"
  // badge) — scope badge assertions to the list itself to avoid ambiguity.
  Finder inList(Finder f) =>
      find.descendant(of: find.byKey(const ValueKey('clipsList')), matching: f);

  testWidgets('defaults to the All Clips destination showing the empty state',
      (t) async {
    await t.pumpWidget(_app(shell()));
    expect(find.textContaining('Alt+F10'), findsOneWidget);
    expect(find.text('All clips'), findsNothing); // empty state, no header
  });

  testWidgets('capture error hides the buffering indicator', (t) async {
    await t.pumpWidget(_app(shell(error: 'libobs init failed')));
    expect(find.textContaining('Buffering'), findsNothing);
    expect(find.text('Capture unavailable'), findsOneWidget);
  });

  testWidgets('paused buffer shows Paused and stops claiming Buffering',
      (t) async {
    final active = ValueNotifier<bool>(true);
    await t.pumpWidget(_app(shell(bufferActive: active)));
    expect(find.textContaining('Buffering'), findsOneWidget);
    active.value = false;
    await t.pump();
    expect(find.textContaining('Buffering'), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('capture error shows banner and disables Save', (t) async {
    await t.pumpWidget(_app(shell(error: 'libobs init failed')));
    expect(find.textContaining('libobs init failed'), findsOneWidget);
    final btn =
        t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save clip'));
    expect(btn.onPressed, isNull);
  });

  testWidgets('active game chip follows coordinator.activeGame', (t) async {
    // Scoped to the chip's key: the rail's pinned "desktop" pseudo-game row
    // shows the same "Desktop" label at rest, which would otherwise collide.
    Finder gameChip() => find.descendant(
        of: find.byKey(const ValueKey('activeGameChip')),
        matching: find.byType(Text));
    await t.pumpWidget(_app(shell()));
    expect(t.widget<Text>(gameChip()).data, 'Desktop');
    coordinator.activeGame.value = 'league_of_legends';
    await t.pump();
    expect(t.widget<Text>(gameChip()).data, 'League of Legends');
  });

  testWidgets('a save error shows a SnackBar with the message', (t) async {
    await t.pumpWidget(_app(shell()));
    coordinator.lastSaveError.value = 'disk full';
    await t.pump(); // schedule the SnackBar
    await t.pump(); // let it animate in
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets('a second identical failure shows the SnackBar again', (t) async {
    await t.pumpWidget(_app(shell()));

    coordinator.lastSaveError.value = 'disk full';
    await t.pump();
    await t.pump();
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);

    // Let the first SnackBar fully dismiss, then repeat the exact failure the
    // way ClipCoordinator._reportSaveError does — null, then the same
    // message — since a plain re-set of an equal value is a no-op on
    // ValueNotifier and would never reach the listener.
    await t.pump(const Duration(seconds: 5));
    coordinator.lastSaveError.value = null;
    coordinator.lastSaveError.value = 'disk full';
    await t.pump();
    await t.pump();
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets(
      'a save error still shows its SnackBar while on a non-All-Clips '
      'destination — the listener lives in the Shell, not the old '
      'per-screen HomeScreen', (t) async {
    await t.pumpWidget(_app(shell()));
    await t.tap(navItem('settings'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    coordinator.lastSaveError.value = 'disk full';
    await t.pump();
    await t.pump();
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets('the Logs rail item opens the Talker screen', (t) async {
    await t.pumpWidget(_app(shell()));
    await t.tap(navItem('logs'));
    await t.pumpAndSettle();
    expect(find.text('Talker'), findsOneWidget);
  });

  testWidgets('rendering the shell does not pre-seed a game config', (t) async {
    // Merely showing "Buffering · N s" must not insert a 'desktop' (or any
    // other) row into settings — that would leak into Settings' per-game
    // section before a game has ever actually been configured.
    await t.pumpWidget(_app(shell()));
    expect(coordinator.settings.allConfigs, isEmpty);
  });

  group('rail', () {
    testWidgets('lists directory entries with clip counts', (t) async {
      coordinator.settings.setConfig(GameConfig(gameId: 'app:cs2'));
      library.add(
          clip('a', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(
          clip('b', 'app:cs2', GameEventKind.manual, DateTime(2026, 7, 2)));
      library.add(
          clip('c', 'desktop', GameEventKind.manual, DateTime(2026, 7, 3)));
      await t.pumpWidget(_app(shell()));

      expect(navGame('app:cs2'), findsOneWidget);
      expect(
          find.descendant(
              of: navGame('app:cs2'), matching: find.text('Counter-Strike 2')),
          findsOneWidget);
      expect(find.descendant(of: navGame('app:cs2'), matching: find.text('2')),
          findsOneWidget);
      expect(navGame('desktop'), findsOneWidget);
      expect(find.descendant(of: navGame('desktop'), matching: find.text('1')),
          findsOneWidget);
    });

    testWidgets('selecting a game filters the content to that game', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(shell()));

      // All Clips (the default destination) shows both.
      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);

      await t.tap(navGame('league_of_legends'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('League of Legends'), findsWidgets);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
      expect(inList(find.text('MANUAL')), findsNothing);
    });

    testWidgets('All Clips destination shows every game\'s clips', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(shell()));

      // Switch away to a game, then back to All Clips, to prove the
      // destination genuinely restores the full library rather than staying
      // filtered.
      await t.tap(navGame('league_of_legends'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(navItem('allClips'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
    });

    testWidgets('the Settings destination renders the embedded SettingsScreen',
        (t) async {
      await t.pumpWidget(_app(shell()));
      expect(find.text('CAPTURE'), findsNothing);

      await t.tap(navItem('settings'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('CAPTURE'), findsOneWidget);
      expect(find.text('HOTKEY'), findsOneWidget);
    });

    testWidgets('the Supported Games placeholder renders for + Add game',
        (t) async {
      await t.pumpWidget(_app(shell()));
      await t.tap(navItem('addGame'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('Supported Games'), findsOneWidget);
    });
  });
}
