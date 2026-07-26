import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/focus_ring.dart';

/// Material's own focus highlight is invisible on every interactive surface
/// in this app: `InkWell` paints `focusColor` into the enclosing Material's
/// ink layer, BEHIND its child, and each of these surfaces draws an opaque
/// background as that child. Measured on the real app, tabbing between filter
/// chips moved ~25 levels on one row of anti-aliased fringe and moved the nav
/// rows not one byte. [FocusRing] paints on top instead.
void main() {
  Widget host({required int rows}) => MaterialApp(
        theme: rewindTheme(),
        home: Scaffold(
          body: Column(
            children: [
              for (var i = 0; i < rows; i++)
                FocusRing(
                  radius: 4,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: () {},
                      // The opaque child that hides the ink highlight — the
                      // whole reason this widget exists.
                      child: Container(
                        height: 40,
                        width: 200,
                        color: const Color(0xFF121418),
                        child: Text('row $i'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  Finder rings() => find.descendant(
        of: find.byType(FocusRing),
        matching: find.byType(DecoratedBox),
      );

  testWidgets('paints nothing until something inside it takes focus',
      (t) async {
    await t.pumpWidget(host(rows: 2));
    await t.pump();
    expect(rings(), findsNothing);
  });

  testWidgets('paints exactly one ring, on the focused row', (t) async {
    await t.pumpWidget(host(rows: 3));
    await t.pump();

    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(rings(), findsOneWidget);

    // ...and it follows focus rather than accumulating.
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(rings(), findsOneWidget);
  });

  testWidgets('adds no tab stop of its own', (t) async {
    // The observing Focus node must be skipTraversal + canRequestFocus:false,
    // or every wrapped control would take two tabs to get past.
    await t.pumpWidget(host(rows: 3));
    await t.pump();

    final seen = <FocusNode>[];
    for (var i = 0; i < 3; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      seen.add(FocusManager.instance.primaryFocus!);
    }
    expect(seen.toSet(), hasLength(3));
  });
}
