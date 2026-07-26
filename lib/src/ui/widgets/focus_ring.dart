import 'package:flutter/material.dart';

import '../theme.dart';

/// Draws a visible focus ring OVER [child] whenever anything inside it holds
/// keyboard focus.
///
/// This exists because Material's own focus highlight is invisible in this
/// app. `InkWell` paints its `focusColor` into the enclosing `Material`'s ink
/// layer, which sits BEHIND the InkWell's child — and every interactive
/// surface in Rewind (nav rows, filter chips, session cards, clip tiles)
/// draws its own opaque background as that child. The highlight is painted
/// every time and covered every time; measured on the real app, tabbing
/// between filter chips moved about 25 levels on a single row of
/// anti-aliased fringe outside the rounded rect, and moved the nav rows not
/// one byte. Keyboard users had no idea where they were.
///
/// A ring on top, rather than a tint underneath, is also the more honest
/// affordance here: these surfaces already use their FILL to mean selected,
/// so focus needed a channel of its own.
///
/// Uses [RewindTokens.interactive] — focus is an interaction affordance, not
/// machine state, so it takes the achromatic steel and never a state hue.
class FocusRing extends StatefulWidget {
  final Widget child;

  /// Matches the ring to whatever the wrapped surface's own corner radius is,
  /// so it reads as that surface lighting up rather than a box around it.
  final double radius;

  const FocusRing({
    required this.child,
    required this.radius,
    super.key,
  });

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    return Focus(
      // Not a stop of its own: this node exists only to observe. Without both
      // of these the ring would insert an extra, invisible tab stop before
      // the control it decorates.
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (hasFocus) {
        if (hasFocus != _focused) setState(() => _focused = hasFocus);
      },
      child: Stack(
        children: [
          widget.child,
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    border: Border.all(color: tokens.interactive, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
