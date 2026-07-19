import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/shell_destination.dart';

void main() {
  group('SettingsDestination', () {
    test('two defaults (no gameId, no tab) are equal', () {
      expect(const SettingsDestination(), const SettingsDestination());
      expect(const SettingsDestination().hashCode,
          const SettingsDestination().hashCode);
    });

    test('same initialTab compares equal', () {
      expect(const SettingsDestination(initialTab: 'Steam'),
          const SettingsDestination(initialTab: 'Steam'));
      expect(const SettingsDestination(initialTab: 'Steam').hashCode,
          const SettingsDestination(initialTab: 'Steam').hashCode);
    });

    test('different initialTab compares unequal', () {
      expect(const SettingsDestination(initialTab: 'Steam'),
          isNot(const SettingsDestination(initialTab: 'Capture')));
    });

    test('a set initialTab differs from the default (null)', () {
      expect(const SettingsDestination(initialTab: 'Steam'),
          isNot(const SettingsDestination()));
    });

    test('initialGameId and initialTab are independent axes', () {
      expect(
        const SettingsDestination(initialGameId: 'lol', initialTab: 'Steam'),
        const SettingsDestination(initialGameId: 'lol', initialTab: 'Steam'),
      );
      expect(
        const SettingsDestination(initialGameId: 'lol'),
        isNot(const SettingsDestination(
            initialGameId: 'lol', initialTab: 'Steam')),
      );
    });
  });
}
