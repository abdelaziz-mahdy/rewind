import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/theme.dart';

/// WCAG 2.1 relative luminance of an opaque color.
double _luminance(Color c) {
  double channel(double v) {
    final s = v; // already 0..1 in Flutter's component accessors
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color fg, Color bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  final lighter = math.max(a, b);
  final darker = math.min(a, b);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  const t = RewindTokens.dark;

  final surfaces = <String, Color>{
    'bg': t.bg,
    'surface': t.surface,
    'surfaceRaised': t.surfaceRaised,
  };

  /// Every token that is ever painted as TEXT or as a legible glyph on one of
  /// the app's three surfaces. The 2026-07-20 audit note used to assert this
  /// in a comment; a dark theme is exactly where "muted on dark" quietly
  /// slips below AA on a retune, so it is a test now (see the
  /// 2026-07-25 broadcast-deck spec §1.1).
  final foregrounds = <String, Color>{
    'text': t.text,
    'textMuted': t.textMuted,
    'textDim': t.textDim,
    'interactive': t.interactive,
    'armed': t.armed,
    'onAir': t.onAir,
    'positive': t.positive,
    'danger': t.danger,
    'warn': t.warn,
    'eventSeed': t.eventSeed,
  };

  group('token contrast (WCAG AA, 4.5:1 normal text)', () {
    for (final fg in foregrounds.entries) {
      for (final bg in surfaces.entries) {
        test('${fg.key} on ${bg.key}', () {
          final ratio = _contrast(fg.value, bg.value);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '${fg.key} on ${bg.key} is ${ratio.toStringAsFixed(2)}:1 '
                '— below the AA normal-text threshold. Retune the token, do '
                'not relax this test.',
          );
        });
      }
    }
  });

  test('the primary button pair clears AAA', () {
    // `interactive` is a near-white FILL with `bg` as its foreground — the
    // inverse of every pair above, and the app's single most important
    // control (Save clip).
    expect(_contrast(t.bg, t.interactive), greaterThanOrEqualTo(7.0));
  });

  test('onAir and danger are distinguishable from each other', () {
    // "You are recording" and "this will delete a file" must never read as
    // the same red (spec §0).
    expect(t.onAir, isNot(equals(t.danger)));
    final delta = (t.onAir.r - t.danger.r).abs() +
        (t.onAir.g - t.danger.g).abs() +
        (t.onAir.b - t.danger.b).abs();
    expect(delta, greaterThan(0.05));
  });

  test('interactive is achromatic — hue may not encode state', () {
    // The one rule (spec §0): chrome carries no hue. A saturated
    // `interactive` would immediately start competing with the state colors
    // for meaning, which is the exact defect this system replaces.
    expect(HSLColor.fromColor(t.interactive).saturation, lessThan(0.3));
    expect(HSLColor.fromColor(t.interactivePressed).saturation, lessThan(0.3));
  });
}
