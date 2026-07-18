import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_registry.dart';

import 'fakes/fake_game_source.dart';

void main() {
  group('GameRegistry.addNewSources', () {
    test('adopts sources with unseen gameIds, skips already-supervised ones',
        () {
      final existing = FakeGameSource('app:already_here');
      final registry = GameRegistry(sources: [existing]);

      final fresh = FakeGameSource('app:brand_new');
      final dup = FakeGameSource('app:already_here', 'Impostor');
      registry.addNewSources([fresh, dup]);

      expect(registry.sources, hasLength(2));
      expect(registry.sources, contains(fresh));
      expect(registry.sources, contains(existing));
      expect(registry.sources, isNot(contains(dup)));
    });

    test('an adopted source is supervised by the very next tick (live add)',
        () async {
      final registry = GameRegistry(sources: []);
      final game = FakeGameSource('app:added_mid_session')..running = true;

      registry.addNewSources([game]);
      await registry.tickNow();

      expect(registry.activeGameIds, contains('app:added_mid_session'));
    });
  });

  group('GameActivity.processMatch stamping', () {
    test(
        'stamps a vendor source\'s processMatch onto GameActivity — not '
        'gated on ProcessWatcherSource anymore (Task 15)', () async {
      final vendor = FakeGameSource(
          'league_of_legends', 'League of Legends', true, 'GameClient')
        ..running = true;
      final registry = GameRegistry(sources: [vendor]);

      GameActivity? activity;
      registry.activity.listen((a) => activity = a);

      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(activity?.processMatch, 'GameClient');
    });

    test('stays null for a source that supplies none', () async {
      final source = FakeGameSource('app:no_needle')..running = true;
      final registry = GameRegistry(sources: [source]);

      GameActivity? activity;
      registry.activity.listen((a) => activity = a);

      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(activity?.processMatch, isNull);
    });
  });
}
