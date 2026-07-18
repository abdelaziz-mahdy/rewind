import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip_markers.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/timeline_markers.dart';

void main() {
  // A plain, dependency-free widget (no media_kit) — see its class doc —
  // so it's tested directly, unlike PlayerScreen which can never be built
  // in a widget test.
  Widget app(Widget child, {double width = 300}) => MaterialApp(
        theme: rewindTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      );

  testWidgets('renders one tick per marker', (t) async {
    final markers = [
      const ClipMarker(kind: GameEventKind.kill, offset: Duration(seconds: 5)),
      const ClipMarker(
          kind: GameEventKind.death, offset: Duration(seconds: 20)),
      const ClipMarker(kind: GameEventKind.ace, offset: Duration(seconds: 25)),
    ];

    await t.pumpWidget(app(TimelineMarkers(
      markers: markers,
      duration: const Duration(seconds: 30),
      onSeek: (_) {},
    )));

    expect(find.byKey(const ValueKey('timelineMarker-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('timelineMarker-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('timelineMarker-2')), findsOneWidget);
  });

  testWidgets('no markers renders nothing (no crash, no stray ticks)',
      (t) async {
    await t.pumpWidget(app(TimelineMarkers(
      markers: const [],
      duration: const Duration(seconds: 30),
      onSeek: (_) {},
    )));

    expect(find.byKey(const ValueKey('timelineMarker-0')), findsNothing);
  });

  testWidgets(
      'ticks are positioned proportionally: an earlier offset renders left '
      'of a later one', (t) async {
    final markers = [
      const ClipMarker(kind: GameEventKind.kill, offset: Duration(seconds: 5)),
      const ClipMarker(
          kind: GameEventKind.death, offset: Duration(seconds: 25)),
    ];

    await t.pumpWidget(app(TimelineMarkers(
      markers: markers,
      duration: const Duration(seconds: 30),
      onSeek: (_) {},
    )));

    final earlyX =
        t.getTopLeft(find.byKey(const ValueKey('timelineMarker-0'))).dx;
    final lateX =
        t.getTopLeft(find.byKey(const ValueKey('timelineMarker-1'))).dx;
    expect(earlyX, lessThan(lateX));
  });

  testWidgets('a marker at offset 0 renders at (or near) the left edge',
      (t) async {
    await t.pumpWidget(app(
      TimelineMarkers(
        markers: const [
          ClipMarker(kind: GameEventKind.kill, offset: Duration.zero),
        ],
        duration: const Duration(seconds: 30),
        onSeek: (_) {},
      ),
      width: 300,
    ));

    final x = t.getTopLeft(find.byKey(const ValueKey('timelineMarker-0'))).dx;
    expect(x, closeTo(0, timelineMarkerWidth));
  });

  testWidgets(
      'a marker at offset == duration renders at (or near) the '
      'right edge', (t) async {
    const width = 300.0;
    await t.pumpWidget(app(
      TimelineMarkers(
        markers: const [
          ClipMarker(kind: GameEventKind.kill, offset: Duration(seconds: 30)),
        ],
        duration: const Duration(seconds: 30),
        onSeek: (_) {},
      ),
      width: width,
    ));

    final x = t.getTopLeft(find.byKey(const ValueKey('timelineMarker-0'))).dx;
    expect(x, closeTo(width - timelineMarkerWidth, timelineMarkerWidth));
  });

  testWidgets(
      'tapping a tick seeks to max(0, offset - 2s), not the offset itself',
      (t) async {
    Duration? seekedTo;
    await t.pumpWidget(app(TimelineMarkers(
      markers: const [
        ClipMarker(kind: GameEventKind.kill, offset: Duration(seconds: 10)),
      ],
      duration: const Duration(seconds: 30),
      onSeek: (d) => seekedTo = d,
    )));

    await t.tap(find.byKey(const ValueKey('timelineMarker-0')));

    expect(seekedTo, const Duration(seconds: 8));
  });

  testWidgets(
      'tapping a tick near the start seeks to zero rather than a negative '
      'duration', (t) async {
    Duration? seekedTo;
    await t.pumpWidget(app(TimelineMarkers(
      markers: const [
        ClipMarker(kind: GameEventKind.kill, offset: Duration(seconds: 1)),
      ],
      duration: const Duration(seconds: 30),
      onSeek: (d) => seekedTo = d,
    )));

    await t.tap(find.byKey(const ValueKey('timelineMarker-0')));

    expect(seekedTo, Duration.zero);
  });

  testWidgets('the tooltip shows the kind name and m:ss', (t) async {
    await t.pumpWidget(app(TimelineMarkers(
      markers: const [
        ClipMarker(
            kind: GameEventKind.pentaKill, offset: Duration(seconds: 90)),
      ],
      duration: const Duration(minutes: 3),
      onSeek: (_) {},
    )));

    expect(find.byTooltip('PENTA KILL · 1:30'), findsOneWidget);
  });
}
