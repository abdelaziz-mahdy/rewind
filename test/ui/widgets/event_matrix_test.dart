import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/event_matrix.dart';

Widget _app(Widget child) =>
    MaterialApp(theme: rewindTheme(), home: Scaffold(body: child));

/// [EventToggleChip] is shared by every auto-clip event matrix in the app
/// (currently only `settings_screen.dart`'s per-game MY GAMES page — the
/// game hub's own inline matrix was removed in favour of a summary card, see
/// `game_hub_screen_test.dart`). These regression tests exercise the chip
/// directly rather than through either host screen, since the bugs they
/// guard are properties of the chip's own rendering, not of where it's used.
void main() {
  Color labelColor(WidgetTester t) => t
      .widget<Text>(find.descendant(
        of: find.byType(EventToggleChip),
        matching: find.byType(Text),
      ))
      .style!
      .color!;

  testWidgets(
      'an ENABLED event is more prominent than a disabled one — the state '
      'used to be inverted', (t) async {
    // Regression: unselected chips drew full-brightness `tokens.text` while
    // selected ones drew the dimmer accent, so a hub's loudest elements were
    // the events the player had switched OFF (KILL enabled read as a
    // whisper next to DRAGON KILL disabled shouting in white).
    await t.pumpWidget(_app(EventToggleChip(
      kind: GameEventKind.kill,
      selected: true,
      onChanged: (_) {},
    )));
    final on = labelColor(t);

    await t.pumpWidget(_app(EventToggleChip(
      kind: GameEventKind.dragonKill,
      selected: false,
      onChanged: (_) {},
    )));
    final off = labelColor(t);

    expect(on, isNot(off));
    // The real assertion: ON must not be dimmer than OFF.
    expect(on.computeLuminance(), greaterThan(off.computeLuminance()),
        reason: 'an enabled event must not read dimmer than a disabled one');
  });

  testWidgets('state is not signalled by colour alone — ON carries a check',
      (t) async {
    // ~14 same-size, same-shape chips distinguished only by hue is nothing
    // to a colour-blind player, so "on" also shows a check glyph.
    await t.pumpWidget(_app(EventToggleChip(
      kind: GameEventKind.kill,
      selected: true,
      onChanged: (_) {},
    )));
    expect(find.byIcon(Icons.check), findsOneWidget);

    await t.pumpWidget(_app(EventToggleChip(
      kind: GameEventKind.dragonKill,
      selected: false,
      onChanged: (_) {},
    )));
    expect(find.byIcon(Icons.check), findsNothing);
  });
}
