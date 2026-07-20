import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/clip/thumbnail_cache.dart';
import 'package:rewind/src/events/game_catalog.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/player_screen.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart';

import '../../fakes/fake_thumbnail_generator.dart';

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
    await t.tap(find.byType(ClipTile));

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
    expect(find.text('Keep'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets(
      'Keep toggles clip.protected, shows the kept badge, and flips the menu '
      'label to Stop keeping', (t) async {
    await t.pumpWidget(app(ClipTile(clip: clip, library: library)));
    expect(find.byKey(const ValueKey('protectedLock')), findsNothing);

    await t.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
    await t.pumpAndSettle();
    await t.tap(find.text('Keep'));
    await t.pumpAndSettle();

    expect(clip.protected, isTrue);
    expect(find.byKey(const ValueKey('protectedLock')), findsOneWidget);

    await t.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
    await t.pumpAndSettle();
    expect(find.text('Stop keeping'), findsOneWidget);
  });

  testWidgets('events defaults to empty (no MatchStats handy — not an error)',
      (t) async {
    await t.pumpWidget(app(ClipTile(clip: clip, library: library)));
    expect(t.widget<ClipTile>(find.byType(ClipTile)).events, isEmpty);
  });

  testWidgets(
      'a caller-supplied events list is retained on the widget '
      '(the contract PlayerScreen is opened with on tap)', (t) async {
    final events = [
      MatchEventStamp(kind: GameEventKind.kill, at: DateTime.now()),
    ];
    await t.pumpWidget(
        app(ClipTile(clip: clip, library: library, events: events)));
    expect(t.widget<ClipTile>(find.byType(ClipTile)).events, same(events));
  });

  group('thumbnail', () {
    testWidgets('with no thumbnails cache, always shows the placeholder glyph',
        (t) async {
      await t.pumpWidget(app(ClipTile(clip: clip, library: library)));
      await t.pump();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets(
        'shows the placeholder first, then swaps to the generated '
        'thumbnail once ready', (t) async {
      // FakeThumbnailGenerator writes with the *Sync dart:io variants
      // deliberately — see its doc comment — so this test never needs real
      // async work driven from outside the widget-test fake-async zone.
      final cache = ThumbnailCache(FakeThumbnailGenerator());

      await t.pumpWidget(
          app(ClipTile(clip: clip, library: library, thumbnails: cache)));

      // Generation is still in flight the very first frame (even a fully
      // synchronous fake still needs a microtask to resolve its Future) —
      // the placeholder glyph shows, no image yet.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      // Bounded pumps flush the queued microtasks that let the fake's
      // (synchronous, already-complete) generation work reach FutureBuilder.
      await t.pump();
      await t.pump();

      expect(find.byType(Image), findsOneWidget);
      // The play-glyph overlay stays visible on top of the image.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('a failed generation leaves the placeholder showing',
        (t) async {
      final cache =
          ThumbnailCache(FakeThumbnailGenerator(failFor: {clip.path}));

      await t.pumpWidget(
          app(ClipTile(clip: clip, library: library, thumbnails: cache)));
      await t.pump();
      await t.pump();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('achievement events', () {
    testWidgets(
        'badge renders the generic "ACHIEVEMENT" text (kind-based, '
        'not the specific unlock name)', (t) async {
      final achievementClip = Clip(
        path: '${tmp.path}/ach.mp4',
        gameId: 'steam:730',
        event: GameEventKind.achievement,
        createdAt: DateTime.now(),
        sizeBytes: 1024,
        eventLabel: 'Winner Winner',
      );
      await t
          .pumpWidget(app(ClipTile(clip: achievementClip, library: library)));
      expect(find.text('ACHIEVEMENT'), findsOneWidget);
    });

    testWidgets(
        'the specific unlock name (Clip.eventLabel) appears in the footer',
        (t) async {
      final achievementClip = Clip(
        path: '${tmp.path}/ach.mp4',
        gameId: 'steam:730',
        event: GameEventKind.achievement,
        createdAt: DateTime.now(),
        sizeBytes: 1024,
        eventLabel: 'Winner Winner',
      );
      await t
          .pumpWidget(app(ClipTile(clip: achievementClip, library: library)));
      expect(find.textContaining('Winner Winner'), findsOneWidget);
    });

    testWidgets('a clip with no eventLabel shows no extra text (unaffected)',
        (t) async {
      await t.pumpWidget(app(ClipTile(clip: clip, library: library)));
      expect(find.textContaining(formatSize(clip.sizeBytes)), findsOneWidget);
    });

    testWidgets('eventColor gives achievement a distinct tint from a kill',
        (t) async {
      late BuildContext ctx;
      await t.pumpWidget(app(Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      })));
      expect(eventColor(ctx, GameEventKind.achievement),
          isNot(eventColor(ctx, GameEventKind.kill)));
    });
  });

  group('card footer', () {
    testWidgets('showGameName (default true) renders the game name', (t) async {
      await t.pumpWidget(app(ClipTile(clip: clip, library: library)));
      expect(find.text(displayNameFor(clip.gameId)), findsOneWidget);
    });

    testWidgets('showGameName: false omits the game name (game hub use)',
        (t) async {
      await t.pumpWidget(
          app(ClipTile(clip: clip, library: library, showGameName: false)));
      expect(find.text(displayNameFor(clip.gameId)), findsNothing);
      // The age/size line is unaffected either way.
      expect(find.textContaining(formatSize(clip.sizeBytes)), findsOneWidget);
    });
  });

  testWidgets(
      'the overflow menu is dimmed at rest, then becomes fully opaque on hover',
      (t) async {
    await t.pumpWidget(app(ClipTile(clip: clip, library: library)));

    Finder overflowOpacity() => find.ancestor(
        of: find.byWidgetPredicate((w) => w is PopupMenuButton),
        matching: find.byType(AnimatedOpacity));

    // Dimmed, not invisible: a fully hidden menu has zero affordance
    // for anyone not already hovering the card.
    expect(t.widget<AnimatedOpacity>(overflowOpacity()).opacity, 0.45);

    final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(t.getCenter(find.byType(ClipTile)));
    await t.pump();

    expect(t.widget<AnimatedOpacity>(overflowOpacity()).opacity, 1);
  });

  group('grid geometry (clipGridChildAspectRatio)', () {
    testWidgets(
        'a card fits the geometry the grid delegate assumes with no '
        'overflow, at the delegate\'s maxCrossAxisExtent width', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: rewindTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: clipGridMaxCrossAxisExtent,
              height: clipGridMaxCrossAxisExtent / clipGridChildAspectRatio,
              child: ClipTile(clip: clip, library: library),
            ),
          ),
        ),
      ));
      await t.pump();

      // A RenderFlex overflow (or any other layout exception) throws during
      // the pump above rather than surfacing as a failed expectation, so
      // this only needs to confirm nothing was thrown.
      expect(t.takeException(), isNull);

      final size = t.getSize(find.byType(ClipTile));
      expect(size.width, clipGridMaxCrossAxisExtent);
      expect(
        size.height,
        closeTo(clipGridMaxCrossAxisExtent / clipGridChildAspectRatio, 0.5),
      );
    });
  });
  group('event badge colors', () {
    testWidgets(
        'multikill tiers escalate to visibly distinct, brighter colors',
        (t) async {
      late Color kill, dbl, triple, quadra, penta, ace;
      await t.pumpWidget(MaterialApp(
        theme: rewindTheme(),
        home: Builder(builder: (context) {
          kill = eventColor(context, GameEventKind.kill);
          dbl = eventColor(context, GameEventKind.doubleKill);
          triple = eventColor(context, GameEventKind.tripleKill);
          quadra = eventColor(context, GameEventKind.quadraKill);
          penta = eventColor(context, GameEventKind.pentaKill);
          ace = eventColor(context, GameEventKind.ace);
          return const SizedBox();
        }),
      ));

      // Every tier is a different color — a penta must never render
      // pixel-identical to a plain kill (the pre-fix bug).
      final tiers = {kill, dbl, triple, quadra, penta};
      expect(tiers, hasLength(5));

      // Lightness climbs monotonically kill -> penta (amber -> gold).
      double light(Color c) => HSLColor.fromColor(c).lightness;
      expect(light(dbl), greaterThan(light(kill)));
      expect(light(triple), greaterThan(light(dbl)));
      expect(light(quadra), greaterThan(light(triple)));
      expect(light(penta), greaterThan(light(quadra)));

      // Ace stays at base amber (a team event, not a personal multikill).
      expect(ace, kill);
    });
  });
}

