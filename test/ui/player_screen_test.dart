import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/player_screen.dart';

// PlayerScreen itself constructs a real media_kit Player in initState,
// which needs the native libmpv libraries that aren't loaded in the
// widget-test host process — pumping the widget crashes the test binary
// rather than failing cleanly. So only the pure, dependency-free pieces
// (time formatting, the shared route name) are covered here; the
// navigation-triggers-a-push behavior is covered in clip_tile_test.dart
// without ever building PlayerScreen (see the comment on
// playerScreenRouteName).
void main() {
  group('formatDuration', () {
    test('zero duration', () {
      expect(formatDuration(Duration.zero), '0:00');
    });

    test('seconds only, zero-padded', () {
      expect(formatDuration(const Duration(seconds: 5)), '0:05');
    });

    test('minutes and seconds', () {
      expect(formatDuration(const Duration(minutes: 3, seconds: 42)), '3:42');
    });

    test('past an hour switches to H:MM:SS', () {
      expect(
        formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });

    test('negative duration clamps to zero', () {
      expect(formatDuration(const Duration(seconds: -5)), '0:00');
    });
  });

  test('playerScreenRouteName is a stable, non-empty route name', () {
    expect(playerScreenRouteName, isNotEmpty);
  });
}
