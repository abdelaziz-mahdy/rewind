import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/widgets/clip_tile.dart';

void main() {
  group('formatSize', () {
    test('one decimal under 10 MB, whole MB above', () {
      expect(formatSize(1024 * 1024), '1.0 MB');
      expect(formatSize(42 * 1024 * 1024), '42 MB');
    });

    // The storage LIMIT is configured in GB ("of 20 GB" in Settings), so a
    // library reported as "1014 MB" left the user dividing by 1024 to compare
    // the two.
    test('rolls over to GB past a gigabyte', () {
      expect(formatSize(1023 * 1024 * 1024), '1023 MB');
      expect(formatSize(1024 * 1024 * 1024), '1.0 GB');
      expect(formatSize(21 * 1024 * 1024 * 1024), '21.0 GB');
    });
  });

  group('relativeAge', () {
    final now = DateTime(2026, 8, 1, 12);

    test('minutes and hours', () {
      expect(relativeAge(now.subtract(const Duration(seconds: 20)), now: now),
          'just now');
      expect(relativeAge(now.subtract(const Duration(minutes: 5)), now: now),
          '5 min ago');
      expect(relativeAge(now.subtract(const Duration(hours: 16)), now: now),
          '16 h ago');
    });

    // Without a days bucket this jumped from "23 h ago" straight to a bare
    // date, so one row of cards carried two different time systems.
    test('days, singular and plural, up to a week', () {
      expect(relativeAge(now.subtract(const Duration(hours: 25)), now: now),
          '1 day ago');
      expect(relativeAge(now.subtract(const Duration(days: 3)), now: now),
          '3 days ago');
      expect(relativeAge(now.subtract(const Duration(days: 6)), now: now),
          '6 days ago');
    });

    test('a plain date once counting days stops helping', () {
      expect(relativeAge(now.subtract(const Duration(days: 7)), now: now),
          '2026-07-25');
      expect(relativeAge(DateTime(2026, 1, 2), now: now), '2026-01-02');
    });
  });
}
