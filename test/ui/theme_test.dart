import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/theme.dart';

void main() {
  test('hover and highlight overlays lighten (visible on dark surfaces)', () {
    final theme = rewindTheme();
    // A dark-on-dark hover once shipped: present in the theme, invisible in
    // the app. Guard: overlays must be light (white-based) and non-zero.
    for (final c in [theme.hoverColor, theme.highlightColor]) {
      expect(c.a, greaterThan(0.03));
      expect(c.r, greaterThan(0.9), reason: 'overlay must lighten, not darken');
      expect(c.g, greaterThan(0.9), reason: 'overlay must lighten, not darken');
      expect(c.b, greaterThan(0.9), reason: 'overlay must lighten, not darken');
    }
  });
}
