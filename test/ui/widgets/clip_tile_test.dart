import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/player_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart';

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

void main() {
  late Directory tmp;
  late ClipLibrary library;
  late Clip clip;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_clip_tile');
    library = ClipLibrary(clipsDir: tmp);
    clip = Clip(
      path: '${tmp.path}/clip.mp4',
      gameId: 'league_of_legends',
      event: GameEventKind.pentaKill,
      createdAt: DateTime.now(),
      sizeBytes: 1024 * 1024,
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Widget app(Widget child, {NavigatorObserver? observer}) => MaterialApp(
        theme: rewindTheme(),
        navigatorObservers: [if (observer != null) observer],
        home: Scaffold(body: child),
      );

  testWidgets(
      'tapping a clip tile pushes the PlayerScreen route without building it',
      (t) async {
    final observer = _RecordingObserver();
    await t.pumpWidget(
      app(ClipTile(clip: clip, library: library), observer: observer),
    );
    // The initial MaterialApp route push already happened during pumpWidget
    // (and settled), so only a tap-triggered push should show up below.
    observer.pushed.clear();

    // Deliberately no `pump()` after the tap: the tap synchronously runs
    // the tap handler (Navigator.push), but the pushed route's builder only
    // runs on the next frame. Asserting here — before that frame — proves
    // the push happened without ever constructing PlayerScreen, which would
    // create a real media_kit Player and need native libmpv (unavailable in
    // the widget-test host process).
    await t.tap(find.byType(ListTile));

    expect(observer.pushed, hasLength(1));
    expect(observer.pushed.single.settings.name, playerScreenRouteName);
  });

  testWidgets(
      'overflow menu offers open-in-default-player alongside reveal/delete',
      (t) async {
    await t.pumpWidget(app(ClipTile(clip: clip, library: library)));

    await t.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
    await t.pumpAndSettle();

    expect(find.text('Open in default player'), findsOneWidget);
    expect(
      find.text(Platform.isMacOS ? 'Reveal in Finder' : 'Reveal in Explorer'),
      findsOneWidget,
    );
    expect(find.text('Delete'), findsOneWidget);
  });
}
