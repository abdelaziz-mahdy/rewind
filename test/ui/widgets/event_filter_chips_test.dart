import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/event_filter_chips.dart';

Widget _app(Widget child) =>
    MaterialApp(theme: rewindTheme(), home: Scaffold(body: child));

Clip _clip(GameEventKind event) => Clip(
      path: '/tmp/c.mp4',
      gameId: 'desktop',
      event: event,
      createdAt: DateTime(2026, 1, 1),
      sizeBytes: 1024,
    );

void main() {
  testWidgets(
      "a chip's rendered height clears the lane's own vertical padding "
      "instead of clipping to a dash (regression: the 40 px lane minus the "
      "ListView's 8+12 padding used to leave only 20 px for a ~34 px chip)",
      (t) async {
    await t.pumpWidget(_app(EventFilterChips(
      clips: [_clip(GameEventKind.kill), _clip(GameEventKind.victory)],
      selected: null,
      onSelected: (_) {},
    )));

    final size = t.getSize(find.byKey(const ValueKey('eventFilterChip:all')));
    expect(size.height, greaterThanOrEqualTo(30));
  });
}
