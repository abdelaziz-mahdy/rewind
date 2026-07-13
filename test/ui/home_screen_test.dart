import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_catalog.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/home_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/game_filter_rail.dart';
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

  HomeScreen home({
    String? error,
    ValueNotifier<bool>? bufferActive,
    VoidCallback? onOpenClipsFolder,
  }) =>
      HomeScreen(
          coordinator: coordinator,
          library: library,
          captureError: error,
          bufferActive: bufferActive,
          hotkeyLabel: 'Alt+F10',
          onOpenSettings: () {},
          onSettingsChanged: (_) async {},
          onOpenClipsFolder: onOpenClipsFolder ?? () {});

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
    expect(find.text('League of Legends'), findsOneWidget);
  });

  testWidgets('the folder AppBar button invokes onOpenClipsFolder', (t) async {
    var opened = false;
    await t.pumpWidget(_app(home(onOpenClipsFolder: () => opened = true)));
    await t.tap(find.widgetWithIcon(IconButton, Icons.folder_open_outlined));
    expect(opened, isTrue);
  });

  testWidgets(
      'the empty-state "Open clips folder" button invokes the '
      'callback', (t) async {
    var opened = false;
    await t.pumpWidget(_app(home(onOpenClipsFolder: () => opened = true)));
    await t.tap(find.widgetWithText(TextButton, 'Open clips folder'));
    expect(opened, isTrue);
  });

  testWidgets('a save error shows a SnackBar with the message', (t) async {
    await t.pumpWidget(_app(home()));
    coordinator.lastSaveError.value = 'disk full';
    await t.pump(); // schedule the SnackBar
    await t.pump(); // let it animate in
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);
  });

  testWidgets('a second identical failure shows the SnackBar again', (t) async {
    await t.pumpWidget(_app(home()));

    coordinator.lastSaveError.value = 'disk full';
    await t.pump();
    await t.pump();
    expect(
        find.textContaining("Couldn't save clip: disk full"), findsOneWidget);

    // Let the first SnackBar fully dismiss, then repeat the exact failure
    // the way ClipCoordinator._reportSaveError does — null, then the same
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

  group('game filter rail', () {
    void addDesktopClip(String name, DateTime createdAt) => library.add(Clip(
        path: '${tmp.path}/$name.mp4',
        gameId: 'desktop',
        event: GameEventKind.manual,
        createdAt: createdAt,
        sizeBytes: 1));

    void addLeagueClip(String name, DateTime createdAt) => library.add(Clip(
        path: '${tmp.path}/$name.mp4',
        gameId: 'league_of_legends',
        event: GameEventKind.pentaKill,
        createdAt: createdAt,
        sizeBytes: 1));

    Finder chip(String id) => find.byKey(ValueKey('gameFilterChip:$id'));
    Finder countIn(Finder chipFinder, int count) =>
        find.descendant(of: chipFinder, matching: find.text('$count'));

    testWidgets('absent with only desktop clips', (t) async {
      addDesktopClip('a', DateTime(2026, 7, 1));
      await t.pumpWidget(_app(home()));
      expect(find.byType(GameFilterRail), findsNothing);
    });

    testWidgets(
        'visible with a single non-desktop game (All + that game), not just '
        '2+ distinct gameIds', (t) async {
      addLeagueClip('a', DateTime(2026, 7, 1));
      await t.pumpWidget(_app(home()));
      expect(find.byType(GameFilterRail), findsOneWidget);
      expect(chip('all'), findsOneWidget);
      expect(chip('league_of_legends'), findsOneWidget);
    });

    testWidgets('chips appear when 2+ gameIds exist with correct counts',
        (t) async {
      addDesktopClip('a', DateTime(2026, 7, 1));
      addDesktopClip('b', DateTime(2026, 7, 2));
      addLeagueClip('c', DateTime(2026, 7, 3));
      await t.pumpWidget(_app(home()));

      expect(chip('all'), findsOneWidget);
      expect(countIn(chip('all'), 3), findsOneWidget);
      expect(chip('desktop'), findsOneWidget);
      expect(countIn(chip('desktop'), 2), findsOneWidget);
      expect(chip('league_of_legends'), findsOneWidget);
      expect(countIn(chip('league_of_legends'), 1), findsOneWidget);
      expect(
          find.descendant(
              of: chip('league_of_legends'),
              matching: find.text('League of Legends')),
          findsOneWidget);
    });

    testWidgets('selecting a chip filters rows', (t) async {
      addDesktopClip('a', DateTime(2026, 7, 1));
      addLeagueClip('b', DateTime(2026, 7, 2));
      await t.pumpWidget(_app(home()));

      // Both event badges visible under "All".
      expect(find.text('MANUAL'), findsOneWidget);
      expect(find.text('PENTA KILL'), findsOneWidget);

      await t.tap(chip('league_of_legends'));
      await t.pump();

      expect(find.text('MANUAL'), findsNothing);
      expect(find.text('PENTA KILL'), findsOneWidget);
    });

    testWidgets('deleting the last clip of the filtered game resets to All',
        (t) async {
      addDesktopClip('a', DateTime(2026, 7, 1));
      addLeagueClip('b', DateTime(2026, 7, 2));
      await t.pumpWidget(_app(home()));

      await t.tap(chip('league_of_legends'));
      await t.pump();
      expect(find.text('PENTA KILL'), findsOneWidget);
      expect(find.text('MANUAL'), findsNothing);

      // Use the synchronous remove() rather than deleteClip() — deleteClip
      // does real File I/O (already covered by clip_library_test.dart's
      // plain test()) which hangs indefinitely inside testWidgets' fake
      // async zone without tester.runAsync(). remove() triggers the same
      // notifyListeners() the filter-reset logic reacts to.
      final leagueClip =
          library.all.firstWhere((c) => c.gameId == 'league_of_legends');
      library.remove(leagueClip);
      await t.pump();

      // Filter reset to All: only the remaining desktop clip's rail is
      // gone (single gameId left) and its row is back.
      expect(find.byType(GameFilterRail), findsNothing);
      expect(find.text('MANUAL'), findsOneWidget);
    });
  });

  group('displayNameFor', () {
    test('known id gets its curated display name', () {
      expect(displayNameFor('league_of_legends'), 'League of Legends');
    });

    test('null or "desktop" resolves to Desktop', () {
      expect(displayNameFor(null), 'Desktop');
      expect(displayNameFor('desktop'), 'Desktop');
    });

    test('a catalog entry resolves to its curated display name', () {
      expect(displayNameFor('app:cs2'), 'Counter-Strike 2');
    });

    test('unknown multi-word id is title-cased on underscores', () {
      expect(displayNameFor('counter_strike_2'), 'Counter Strike 2');
    });
  });
}
