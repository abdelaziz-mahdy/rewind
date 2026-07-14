import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/all_clips_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart' show formatSize;

Widget _app(Widget child) =>
    MaterialApp(theme: rewindTheme(), home: Scaffold(body: child));

void main() {
  late Directory tmp;
  late ClipLibrary library;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_all_clips');
    library = ClipLibrary(clipsDir: tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Clip clip(String name, String gameId, GameEventKind event, DateTime createdAt,
          {int sizeBytes = 1024}) =>
      Clip(
          path: '${tmp.path}/$name.mp4',
          gameId: gameId,
          event: event,
          createdAt: createdAt,
          sizeBytes: sizeBytes);

  AllClipsScreen screen({
    String? gameId,
    VoidCallback? onOpenClipsFolder,
  }) =>
      AllClipsScreen(
        library: library,
        hotkeyLabel: 'Alt+F10',
        onOpenClipsFolder: onOpenClipsFolder ?? () {},
        gameId: gameId,
      );

  Finder eventChip(String name) =>
      find.byKey(ValueKey('eventFilterChip:$name'));
  Finder countIn(Finder chipFinder, int count) =>
      find.descendant(of: chipFinder, matching: find.text('$count'));

  // The event-kind chip row and the clip list can show the same uppercase
  // badge text (e.g. a "PENTA KILL" chip label alongside a clip's "PENTA
  // KILL" badge) — scope badge/title assertions to the list itself so they
  // don't collide with the filter chips.
  Finder inList(Finder f) =>
      find.descendant(of: find.byKey(const ValueKey('clipsList')), matching: f);

  testWidgets('empty state shows the hotkey hint', (t) async {
    await t.pumpWidget(_app(screen()));
    expect(find.textContaining('Alt+F10'), findsOneWidget);
  });

  testWidgets('the empty-state "Open clips folder" button invokes the callback',
      (t) async {
    var opened = false;
    await t.pumpWidget(_app(screen(onOpenClipsFolder: () => opened = true)));
    await t.tap(find.widgetWithText(TextButton, 'Open clips folder'));
    expect(opened, isTrue);
  });

  testWidgets('header shows clip count and total size', (t) async {
    library.add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1),
        sizeBytes: 2 * 1024 * 1024));
    library.add(clip('b', 'desktop', GameEventKind.manual, DateTime(2026, 7, 2),
        sizeBytes: 3 * 1024 * 1024));
    await t.pumpWidget(_app(screen()));

    expect(find.text('All clips'), findsOneWidget);
    expect(find.textContaining('2 clips · ${formatSize(5 * 1024 * 1024)}'),
        findsOneWidget);
  });

  testWidgets('the header folder button invokes onOpenClipsFolder', (t) async {
    var opened = false;
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    await t.pumpWidget(_app(screen(onOpenClipsFolder: () => opened = true)));
    await t.tap(find.widgetWithIcon(IconButton, Icons.folder_open_outlined));
    expect(opened, isTrue);
  });

  testWidgets('clips render newest-first with event badge', (t) async {
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
        DateTime(2026, 7, 2)));
    await t.pumpWidget(_app(screen()));

    expect(inList(find.text('PENTA KILL')), findsOneWidget);
    expect(inList(find.text('MANUAL')), findsOneWidget);
    final pentaTop = t.getTopLeft(inList(find.text('PENTA KILL'))).dy;
    final manualTop = t.getTopLeft(inList(find.text('MANUAL'))).dy;
    expect(pentaTop, lessThan(manualTop));
  });

  testWidgets('library updates reactively when a clip is added', (t) async {
    await t.pumpWidget(_app(screen()));
    library
        .add(clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
    await t.pump();
    expect(find.text('MANUAL'), findsOneWidget);
  });

  group('event-kind filter chips', () {
    testWidgets('one chip per distinct event kind, with counts', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(
          clip('b', 'desktop', GameEventKind.manual, DateTime(2026, 7, 2)));
      library.add(clip('c', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 3)));
      await t.pumpWidget(_app(screen()));

      expect(eventChip('all'), findsOneWidget);
      expect(countIn(eventChip('all'), 3), findsOneWidget);
      expect(eventChip('manual'), findsOneWidget);
      expect(countIn(eventChip('manual'), 2), findsOneWidget);
      expect(eventChip('pentaKill'), findsOneWidget);
      expect(countIn(eventChip('pentaKill'), 1), findsOneWidget);
    });

    testWidgets('selecting a chip filters the list to that kind', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(screen()));

      expect(inList(find.text('MANUAL')), findsOneWidget);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);

      await t.tap(eventChip('pentaKill'));
      await t.pump();

      expect(inList(find.text('MANUAL')), findsNothing);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
    });

    testWidgets(
        'deleting the last clip of the filtered kind resets the filter to All',
        (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(screen()));

      await t.tap(eventChip('pentaKill'));
      await t.pump();
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
      expect(inList(find.text('MANUAL')), findsNothing);

      // Synchronous remove() (not deleteClip(), which does real file I/O and
      // would hang the fake-async test zone) still fires the same
      // notifyListeners() the pruning logic reacts to.
      final pentaClip =
          library.all.firstWhere((c) => c.event == GameEventKind.pentaKill);
      library.remove(pentaClip);
      await t.pump();

      // Filter reset to All: the remaining desktop clip is visible again.
      expect(inList(find.text('MANUAL')), findsOneWidget);
    });
  });

  group('gameId scoping (interim per-game view)', () {
    testWidgets('titles the header with the game\'s display name', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      library.add(clip('b', 'league_of_legends', GameEventKind.pentaKill,
          DateTime(2026, 7, 2)));
      await t.pumpWidget(_app(screen(gameId: 'league_of_legends')));

      final title = t.widget<Text>(find.byKey(const ValueKey('allClipsTitle')));
      expect(title.data, 'League of Legends');
      expect(find.text('All clips'), findsNothing);
      expect(inList(find.text('PENTA KILL')), findsOneWidget);
      expect(inList(find.text('MANUAL')), findsNothing);
    });

    testWidgets(
        'an empty scope shows the empty state, not "no clips" from '
        'other games', (t) async {
      library.add(
          clip('a', 'desktop', GameEventKind.manual, DateTime(2026, 7, 1)));
      await t.pumpWidget(_app(screen(gameId: 'league_of_legends')));

      expect(find.text('No clips yet'), findsOneWidget);
    });
  });
}
